"""
Cook County drive-through coffee: site-selection explorer (Streamlit)

Move the priority sliders and the app rescores all 11,584 half-kilometer hexagons, finds the best distinct sites,
and re-runs a weight stress test to show how stable each site is. It reads the same exported factors as the
public map (see prepare_app_data.py), so there is no database and no API key.

Hypothetical project built for a portfolio; not a real site recommendation.
Sources: Overture Maps (places), a public chain-location list, U.S. Census Bureau ACS 5-year (Census Data API;
this product is not endorsed or certified by the Census Bureau), IDOT traffic counts. Derived values are my own
calculations. Basemap: OpenFreeMap, data from OpenStreetMap contributors.
"""
import json
from pathlib import Path
from types import SimpleNamespace
from urllib.parse import quote

import numpy as np
import pandas as pd
import pydeck as pdk
import streamlit as st
from scipy.spatial import cKDTree

st.set_page_config(page_title="Cook County coffee site explorer", layout="wide")

DATA = Path(__file__).parent / "data"
# Replace these two links after the map is published on GitHub Pages
MAP_URL = "https://burlesongis.github.io/cook-county-coffee/web/"
ABOUT_URL = "https://burlesongis.github.io/cook-county-coffee/web/about.html"

# Same five groups, and the same weights inside each group, as the map (web/index.html).
GROUPS = [
    dict(id="compet", name="Competition", hint="Few coffee shops nearby, and many residents per shop",
         parts=[("s_comp", 0.18), ("s_rpc", 0.12)]),
    dict(id="people", name="People and income", hint="Residents within 1.5 km and household income",
         parts=[("s_pop", 0.13), ("s_inc", 0.13)]),
    dict(id="driving", name="Driving habits", hint="Share who drive alone; few households without a vehicle",
         parts=[("s_da", 0.08), ("s_nov", 0.05)]),
    dict(id="traffic", name="Road traffic", hint="Busiest arterial nearby and how much busy road",
         parts=[("s_traf", 0.12), ("s_busy", 0.03)]),
    dict(id="nearby", name="Nearby businesses", hint="Gas stations, fast food, offices, grocery",
         parts=[("s_gas", 0.05), ("s_ff", 0.05), ("s_off", 0.03), ("s_groc", 0.03)]),
]
for g in GROUPS:
    g["base"] = sum(w for _, w in g["parts"])
    g["default"] = round(g["base"] * 100)
ING = [p for g in GROUPS for p, _ in g["parts"]]          # 12 factors, in a fixed order

PRESETS = {
    "My defaults": {},
    "No competition terms": {"compet": 0},
    "Demand only (people x2, no competition)": {"compet": 0, "people": 52},
    "No road traffic terms": {"traffic": 0},
    "Competition doubled": {"compet": 60},
}

RAMP = np.array([[238, 240, 238], [207, 227, 225], [147, 198, 196], [79, 158, 164], [31, 116, 128], [13, 71, 102]])
BREAKS = [35, 45, 55, 63, 70]
RAMP_LABELS = ["Under 35", "35 to 45", "45 to 55", "55 to 63", "63 to 70", "70 and up"]
BASEMAP = "https://tiles.openfreemap.org/styles/positron"
# A plain light-gray style, used when the basemap is switched off (also works with no internet access)
BLANK = "data:application/json;charset=utf-8," + quote(json.dumps(
    {"version": 8, "sources": {}, "layers": [{"id": "bg", "type": "background", "paint": {"background-color": "#f2f3f2"}}]}))
EDGE_M = 288.675                                         # hexagon edge length (500 m across the flat sides)


# ------------------------------------------------------------------------------------------------
# Data
# ------------------------------------------------------------------------------------------------
@st.cache_resource
def load():
    df = pd.read_csv(DATA / "hex_cells.csv")
    sites = pd.read_csv(DATA / "sites.csv")
    lat0 = 41.85
    kx, ky = 111320 * np.cos(np.radians(lat0)), 110950.0
    xy = np.column_stack([(df.lon.to_numpy() + 87.8) * kx, (df.lat.to_numpy() - lat0) * ky])
    sxy = np.column_stack([(sites.lon.to_numpy() + 87.8) * kx, (sites.lat.to_numpy() - lat0) * ky])
    ang = np.radians(np.arange(6) * 60)
    dlon = EDGE_M * np.cos(ang)[None, :] / (111320 * np.cos(np.radians(df.lat.to_numpy()))[:, None])
    dlat = EDGE_M * np.sin(ang)[None, :] / 111000
    poly = np.stack([df.lon.to_numpy()[:, None] + dlon, df.lat.to_numpy()[:, None] + dlat], axis=2).round(5).tolist()
    return SimpleNamespace(
        df=df, sites=sites, xy=xy, sxy=sxy, poly=poly,
        S=df[ING].fillna(0).to_numpy(float),
        pop=df.pop_1_5km.fillna(0).to_numpy(float),
        nov=df.no_vehicle.fillna(0).to_numpy(float),
        tie=df.lat.rank(method="first").to_numpy(),      # equal scores: the more southern cell wins (matches the database)
        elig_default=df.eligible.astype(str).str.lower().eq("true").to_numpy(),
        site_tree=cKDTree(sxy),
    )


D = load()


def ingredient_weights(wg):
    """Group slider values -> the 12 factor weights (sum to 1). Inside a group the split stays fixed."""
    total = sum(wg.values()) or 1
    out = []
    for g in GROUPS:
        for _, w in g["parts"]:
            out.append(wg[g["id"]] / total * w / g["base"])
    return np.array(out)


def eligible_mask(min_pop, max_nv):
    """At the default rules use the exact flag from the database; otherwise apply the rules to the stored values
    (no-vehicle share is stored to two decimals, so cells right at the limit can differ slightly)."""
    if min_pop == 5000 and abs(max_nv - 0.15) < 1e-9:
        return D.elig_default
    return (D.pop >= min_pop) & (D.nov <= max_nv + 1e-9)


@st.cache_data(show_spinner=False)
def peak_graph(min_pop, max_nv, spacing_m):
    """Eligible cells and every pair of eligible cells closer than the spacing."""
    ids = np.flatnonzero(eligible_mask(min_pop, max_nv))
    pairs = cKDTree(D.xy[ids]).query_pairs(spacing_m, output_type="ndarray")
    a = np.concatenate([pairs[:, 0], pairs[:, 1]])
    b = np.concatenate([pairs[:, 1], pairs[:, 0]])
    return ids, a, b, D.tie[ids]


def find_peaks(score, a, b, k):
    """Local peaks: eligible cells that no other eligible cell within the spacing beats (ties go to the lower key k)."""
    sa, sb = score[a], score[b]
    beaten = np.zeros(score.size, bool)
    beaten[a[(sb > sa) | ((sb == sa) & (k[b] < k[a]))]] = True
    p = np.flatnonzero(~beaten)
    return p[np.lexsort((k[p], -score[p]))]              # best first


@st.cache_data(show_spinner=False)
def stability(w_tuple, n_runs, spread, min_pop, max_nv, spacing_m, n_sites):
    """Share of random re-weightings (each factor weight x 0.5-1.5 by default) in which each eligible cell is a top-N site."""
    ids, a, b, k = peak_graph(min_pop, max_nv, spacing_m)
    S = D.S[ids]
    w0 = np.array(w_tuple)
    rng = np.random.default_rng(42)
    hits = np.zeros(ids.size)
    for _ in range(n_runs):
        w = w0 * rng.uniform(1 - spread, 1 + spread, w0.size)
        score = np.round(S @ (w / w.sum()), 1)
        hits[find_peaks(score, a, b, k)[:n_sites]] += 1
    return hits / n_runs


# ------------------------------------------------------------------------------------------------
# Sidebar: priorities and rules
# ------------------------------------------------------------------------------------------------
for g in GROUPS:
    st.session_state.setdefault("w_" + g["id"], g["default"])


def apply_preset():
    over = PRESETS[st.session_state["preset"]]
    for g in GROUPS:
        st.session_state["w_" + g["id"]] = over.get(g["id"], g["default"])


with st.sidebar:
    st.header("Priorities")
    st.caption("Give a factor more or less say. The score re-scales, so only the balance matters.")
    st.selectbox("Start from a preset", list(PRESETS), key="preset", on_change=apply_preset)
    wg = {}
    for g in GROUPS:
        wg[g["id"]] = st.slider(g["name"], 0, 100, key="w_" + g["id"], help=g["hint"])
    total = sum(wg.values())
    if total == 0:
        st.error("Set at least one slider above zero.")
        st.stop()
    shares = " | ".join(f"{g['name'].split()[0]} {round(100 * wg[g['id']] / total)}%" for g in GROUPS)
    st.caption(f"Sliders total {total}. Share of the score: {shares}")

    st.header("Which cells count")
    min_pop = st.slider("Minimum residents within 1.5 km", 0, 20000, 5000, 500)
    max_nv = st.slider("Maximum share of households without a vehicle", 0.05, 0.50, 0.15, 0.01)
    spacing_km = st.slider("Distance between distinct sites (km)", 1.0, 6.0, 3.0, 0.5)
    n_sites = st.slider("Number of sites to show", 5, 25, 15)

    st.header("Stress test")
    do_stab = st.checkbox("Check how stable each site is", value=True)
    n_runs = st.select_slider("Random re-weightings", options=[50, 100, 200, 300], value=100)
    spread = st.slider("How far each weight can move", 0.1, 0.9, 0.5, 0.1,
                       help="Each factor weight is multiplied by a random number between 1 minus this and 1 plus this.")
    basemap = st.checkbox("Show basemap", value=True)

# ------------------------------------------------------------------------------------------------
# Compute
# ------------------------------------------------------------------------------------------------
w = ingredient_weights(wg)
# At the default weights use the database's own score so the list matches the published map exactly;
# otherwise rebuild it from the stored 0-100 factors (same formula, so it can differ by a few tenths).
is_default = all(wg[g["id"]] == g["default"] for g in GROUPS)
score_all = D.df.score.to_numpy(float) if is_default else D.S @ w
ids, pa, pb, pk = peak_graph(min_pop, max_nv, spacing_km * 1000)
score_e = np.round(score_all[ids], 1)
order = find_peaks(score_e, pa, pb, pk)
top = order[:n_sites]
top_cells = ids[top]

stab = stability(tuple(w), n_runs, spread, min_pop, max_nv, spacing_km * 1000, n_sites)[top] if do_stab else None

# Match to the published map's local peaks (within 150 m) for site names and the published top-15 flag
dist, near = D.site_tree.query(D.xy[top_cells], distance_upper_bound=150)
matched = np.isfinite(dist)
pub = D.sites.iloc[np.where(matched, near, 0)].reset_index(drop=True)
in_pub15 = matched & pub.top15.to_numpy()

rows = pd.DataFrame({
    "Rank": np.arange(1, top.size + 1),
    "Score": score_e[top],
    "Residents within 1.5 km": D.pop[top_cells].astype(int),
    "Competitors counted": D.df.comp_eff.to_numpy()[top_cells],
    "Household income ($k)": D.df.income_k.to_numpy()[top_cells],
    "Near": np.where(matched, pub.nearest_roads.fillna(""), ""),
    "In the map's top 15": np.where(in_pub15, "Yes", np.where(matched, "Local peak", "New")),
    "Longitude": D.df.lon.to_numpy()[top_cells].round(5),
    "Latitude": D.df.lat.to_numpy()[top_cells].round(5),
})
if stab is not None:
    rows.insert(3, f"Top {n_sites} in % of stress tests", (100 * stab).round().astype(int))

# ------------------------------------------------------------------------------------------------
# Page
# ------------------------------------------------------------------------------------------------
st.title("Where could a drive-through coffee shop fit in Cook County?")
st.markdown(
    "11,584 half-kilometer hexagons scored on competition, people, driving habits, road traffic and nearby businesses. "
    "Move the sliders in the sidebar to change the priorities and see which sites hold up. "
    "A hypothetical portfolio project, not a real site recommendation. "
    f"[Map with drive-time areas]({MAP_URL}) | [About and method]({ABOUT_URL})"
)

c1, c2, c3, c4 = st.columns(4)
c1.metric("Candidate cells", f"{ids.size:,}")
c2.metric("Distinct local peaks", f"{order.size:,}")
c3.metric(f"Of the map's top 15, in your top {n_sites}", int(in_pub15.sum()))
c4.metric("Best score", f"{score_e[top[0]]:.1f}" if top.size else "n/a")

# Map
cols = np.digitize(score_all, BREAKS)
alpha = np.where(eligible_mask(min_pop, max_nv), 215, 70)
fill = np.column_stack([RAMP[cols], alpha]).astype(int).tolist()
tips = [f"<b>Score {s:.1f}</b><br/>{int(p):,} residents within 1.5 km<br/>{c:g} competitors counted"
        for s, p, c in zip(score_all, D.pop, D.df.comp_eff.fillna(0).to_numpy())]
hexes = pd.DataFrame({"polygon": D.poly, "fill": fill, "tip": tips})
site_df = pd.DataFrame({
    "lon": rows["Longitude"], "lat": rows["Latitude"], "rank": rows["Rank"].astype(str),
    "tip": [f"<b>Site {r}</b><br/>Score {s:.1f}" for r, s in zip(rows["Rank"], rows["Score"])],
})
layers = [
    pdk.Layer("PolygonLayer", hexes, get_polygon="polygon", get_fill_color="fill", stroked=False, pickable=True),
    pdk.Layer("ScatterplotLayer", site_df, get_position=["lon", "lat"], get_radius=700, radius_min_pixels=9, radius_max_pixels=15,
              get_fill_color=[232, 89, 12, 255], get_line_color=[255, 255, 255, 255], line_width_min_pixels=2,
              stroked=True, pickable=True),
    pdk.Layer("TextLayer", site_df, get_position=["lon", "lat"], get_text="rank", get_size=13,
              get_color=[255, 255, 255, 255], get_alignment_baseline="'center'", get_text_anchor="'middle'"),
]
deck = pdk.Deck(
    layers=layers,
    initial_view_state=pdk.ViewState(latitude=41.84, longitude=-87.84, zoom=8.9, pitch=0),
    map_provider="carto", map_style=BASEMAP if basemap else BLANK,
    tooltip={"html": "{tip}", "style": {"fontSize": "12px"}},
)
st.pydeck_chart(deck, height=640)
swatches = "".join(
    f"<span style='display:inline-block;width:14px;height:14px;background:rgb({r},{g},{b});border:1px solid #bbb;"
    f"margin:0 4px -2px 12px'></span>{lab}" for (r, g, b), lab in zip(RAMP, RAMP_LABELS))
st.markdown(f"<div style='font-size:13px'><b>Score</b>{swatches}</div>", unsafe_allow_html=True)
st.caption("Faded hexagons are not candidates (too few residents, or too many households without a vehicle). "
           "Orange circles are your top sites. Scores can differ from the map by a few tenths because the factors are stored as whole numbers.")

st.subheader(f"Top {top.size} sites with your priorities")
st.dataframe(rows.drop(columns=["Longitude", "Latitude"]), hide_index=True)
st.download_button("Download these sites (CSV)", rows.to_csv(index=False).encode("utf-8"), "top_sites.csv", "text/csv")
if stab is not None:
    st.caption(f"Stability: {n_runs} random re-weightings, each factor weight multiplied by a random number between "
               f"{1 - spread:.1f} and {1 + spread:.1f}. 100% means the site made your top {n_sites} every time. "
               "Sites far below 100% depend on exactly how much you value each factor. The percentages differ a little from "
               "the map because this app draws its own random re-weightings.")

with st.expander("How the score works"):
    st.markdown(
        "Each of 12 factors is measured within 1.5 km of a hexagon's center and converted to a percent rank across all "
        "cells (0 to 100, higher is better for the site). The five sliders scale groups of factors, then the weighted "
        "average is the score. Fewer competitors, more residents per competitor, more residents, higher income, more "
        "drive-alone commuters, fewer households without a vehicle, busy arterial roads nearby, and nearby gas stations, "
        "fast food, offices and grocery stores all raise the score. Freeways are left out. "
        "Distinct sites are local peaks: candidate cells that outscore every other candidate within the chosen distance."
    )
with st.expander("Limits"):
    st.markdown(
        "- **Competition is a lower bound.** Overture is incomplete and the chain list covers four chains and no independent shops.\n"
        "- **Traffic counts are not audiences.** They are vehicle counts, from Illinois only.\n"
        "- **Only Cook County hexagons are scored**, but residents and shops are counted from Cook and its neighboring counties.\n"
        "- **No site-level reality.** Parcels, zoning, lot access, rent and permitting are not in the data.\n"
        f"- **Drive-time areas** are on the [map]({MAP_URL}), not in this app."
    )
st.caption(
    "Sources: Overture Maps, a public chain-location list, U.S. Census Bureau ACS 5-year via the Census Data API "
    "(this product is not endorsed or certified by the Census Bureau), IDOT traffic counts. Scores are my own calculations. "
    "Basemap: OpenFreeMap, data from OpenStreetMap contributors."
)
