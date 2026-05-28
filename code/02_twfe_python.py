"""
02_twfe_python.py
-----------------
TWFE estimation pipeline for the California EV-charging / gasoline
displacement project.

When you press Run this script:
    1. Loads `analytic.panel_county_year` either from SQL Server
       (pyodbc, EVPanel database built by 01_preprocess_panel.sql) or
       rebuilds the same panel from the raw CSVs in ../data/ if the
       database is not available.
    2. Estimates five TWFE specifications and a 10-period event study
       around the 2022 NEVI break (Section 1 of the Methodology Plan).
    3. Writes outputs to ./output/:
           panel_for_r.csv              - identical panel for the R script
           twfe_results_python.csv      - point estimates + cluster SEs
           twfe_event_study_python.csv  - event-time leads / lags
           twfe_event_study.png         - publication-ready event plot

All variables match the column names produced by the SQL script and the
headers of the data files (ca_counties.csv, ev_charging_stations_ca.csv,
annual_aqi_by_county_<year>.csv, annual_conc_by_monitor_<year>.csv,
census_acs_county_data.csv, rural_classification.csv,
vehicle_fuel_type_counts_2025.csv, fuel_tax_stats.csv,
eia_seds_gasoline_ca.csv).

Required packages:
    pip install pandas numpy linearmodels shapely matplotlib pyodbc

Optional (only for the SQL Server path):
    Microsoft ODBC Driver 17 or 18 for SQL Server.

Author: Khoi Van
"""

from __future__ import annotations

import os
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

warnings.filterwarnings("ignore", category=FutureWarning)
warnings.filterwarnings("ignore", category=RuntimeWarning)

# --------------------------------------------------------------------
# 0. Paths
# --------------------------------------------------------------------
HERE     = Path(__file__).resolve().parent
ROOT     = HERE.parent
DATA_DIR = ROOT / "data"
OUT_DIR  = HERE / "output"
OUT_DIR.mkdir(parents=True, exist_ok=True)

AQ_DIR   = DATA_DIR / "air_quality"
EV_DIR   = DATA_DIR / "ev_charging_infrastructure"
GAS_DIR  = DATA_DIR / "gasoline_consumption"
RUR_DIR  = DATA_DIR / "rurality_classification"
ACS_DIR  = DATA_DIR / "sociodemographic"
GEO_DIR  = DATA_DIR / "county_spatial_data"
ZEV_DIR  = DATA_DIR / "zev_registrations_fleet_composition"

YEARS = list(range(2010, 2026))

OUTCOME    = "log_gasoline_pc"
ENTITY_VAR = "fips"
TIME_VAR   = "year_id"
COVARS = [
    "log_med_hh_inc",
    "log_population",
    "share_under_150k",
    "share_white_nh",
    "share_owner_occupied",
    "share_drove_alone",
]

# --------------------------------------------------------------------
# 1. SQL Server path (preferred; falls back to raw build)
# --------------------------------------------------------------------
SQL_SERVER   = os.environ.get("SQL_SERVER",   r"localhost\SQLEXPRESS")
SQL_DATABASE = os.environ.get("SQL_DATABASE", "EVPanel")


def _try_pyodbc_drivers():
    try:
        import pyodbc
    except ImportError:
        return []
    return [d for d in pyodbc.drivers() if "SQL Server" in d]


def try_load_from_sql():
    drivers = _try_pyodbc_drivers()
    if not drivers or not SQL_SERVER:
        return None
    import pyodbc
    preferred = sorted(drivers,
                       key=lambda d: ("ODBC Driver" in d, d), reverse=True)
    for drv in preferred:
        conn_str = (
            f"DRIVER={{{drv}}};"
            f"SERVER={SQL_SERVER};DATABASE={SQL_DATABASE};"
            f"Trusted_Connection=yes;TrustServerCertificate=yes;"
        )
        try:
            with pyodbc.connect(conn_str, timeout=5) as cn:
                df = pd.read_sql(
                    "SELECT * FROM analytic.panel_county_year "
                    "ORDER BY fips, year_id;",
                    cn,
                )
            df["fips"]    = df["fips"].astype(str).str.zfill(5)
            df["year_id"] = df["year_id"].astype(int)
            print(f"[sql] loaded {len(df)} rows from {SQL_DATABASE} via {drv}")
            return df
        except Exception:
            continue
    return None


# --------------------------------------------------------------------
# 2. Raw-CSV build (only used when SQL Server is unavailable)
# --------------------------------------------------------------------
def _read_csv(path, **kw):
    return pd.read_csv(path, encoding="utf-8-sig", low_memory=False, **kw)


def haversine_km(lat1, lon1, lat2, lon2):
    R = 6371.0
    lat1, lon1, lat2, lon2 = map(np.radians, [lat1, lon1, lat2, lon2])
    dlat = lat2 - lat1
    dlon = lon2 - lon1
    a = np.sin(dlat/2)**2 + np.cos(lat1) * np.cos(lat2) * np.sin(dlon/2)**2
    return 2 * R * np.arcsin(np.sqrt(a))


def load_counties() -> pd.DataFrame:
    from shapely import wkt
    f = GEO_DIR / "ca_counties.csv"
    df = _read_csv(f)
    df = df[df["STATEFP"].astype(int) == 6].copy()
    df["fips"] = (df["STATEFP"].astype(int) * 1000
                  + df["COUNTYFP"].astype(int)).map(lambda v: f"{v:05d}")
    df["county_name"]  = df["NAME"]
    df["centroid_lat"] = df["INTPTLAT"].astype(float)
    df["centroid_lon"] = df["INTPTLON"].astype(float)
    df["aland_m2"]     = df["ALAND"].astype("int64")
    df["polygon"]      = df["geometry"].map(wkt.loads)
    return df[["fips", "county_name", "centroid_lat", "centroid_lon",
               "aland_m2", "polygon"]].reset_index(drop=True)


def load_ev_stations(counties: pd.DataFrame) -> pd.DataFrame:
    from shapely.geometry import Point
    from shapely.strtree import STRtree
    f = EV_DIR / "ev_charging_stations_ca.csv"
    df = _read_csv(f)
    df = df[(df["fuel_type_code"] == "ELEC")
            & (df["state"] == "CA")
            & (df["status_code"] == "E")].copy()
    df["open_date"] = pd.to_datetime(df["open_date"], errors="coerce")
    df = df[df["open_date"].notna()]
    df["latitude"]  = pd.to_numeric(df["latitude"],  errors="coerce")
    df["longitude"] = pd.to_numeric(df["longitude"], errors="coerce")
    df = df[df["latitude"].between(32.0, 42.5)
            & df["longitude"].between(-125.0, -113.0)]
    df["dcfc_n"] = pd.to_numeric(df["ev_dc_fast_num"],   errors="coerce").fillna(0)
    df["l2_n"]   = pd.to_numeric(df["ev_level2_evse_num"], errors="coerce").fillna(0)
    df["l1_n"]   = pd.to_numeric(df["ev_level1_evse_num"], errors="coerce").fillna(0)
    df = df[(df["dcfc_n"] + df["l2_n"] + df["l1_n"]) > 0].reset_index(drop=True)

    polys = counties["polygon"].tolist()
    fips  = counties["fips"].tolist()
    tree  = STRtree(polys)
    lat_arr = df["latitude"].to_numpy()
    lon_arr = df["longitude"].to_numpy()
    pts = [Point(lon, lat) for lat, lon in zip(lat_arr, lon_arr)]
    centroid_lat = counties["centroid_lat"].to_numpy()
    centroid_lon = counties["centroid_lon"].to_numpy()

    assigned = [None] * len(pts)
    for i, p in enumerate(pts):
        cand = tree.query(p)
        for j in cand:
            if polys[j].covers(p):
                assigned[i] = fips[j]
                break
        if assigned[i] is None:
            d = haversine_km(lat_arr[i], lon_arr[i],
                             centroid_lat, centroid_lon)
            assigned[i] = fips[int(np.argmin(d))]

    df["fips"]    = assigned
    df["year_id"] = df["open_date"].dt.year
    df["zip"]     = df["zip"].astype(str).str.extract(r"(\d{5})")[0]
    return df[["fips", "year_id", "dcfc_n", "l2_n", "zip"]]


def build_ev_dose(counties, stations) -> pd.DataFrame:
    grid = counties[["fips"]].merge(pd.DataFrame({"year_id": YEARS}),
                                     how="cross")
    opens = (stations.groupby(["fips", "year_id"], as_index=False)
             [["dcfc_n", "l2_n"]].sum()
             .rename(columns={"dcfc_n": "dcfc_opened",
                              "l2_n":   "l2_opened"}))
    p = grid.merge(opens, on=["fips", "year_id"], how="left").fillna(
        {"dcfc_opened": 0, "l2_opened": 0})
    p = p.sort_values(["fips", "year_id"])
    p["dcfc_cum"] = p.groupby("fips")["dcfc_opened"].cumsum()
    p["l2_cum"]   = p.groupby("fips")["l2_opened"].cumsum()
    return p[["fips", "year_id", "dcfc_cum", "l2_cum"]]


def load_acs() -> pd.DataFrame:
    f = ACS_DIR / "census_acs_county_data.csv"
    df = _read_csv(f)
    df["fips"] = (df["state_fips"].astype(int) * 1000
                  + df["county_fips"].astype(int)).map(lambda v: f"{v:05d}")
    df["log_med_hh_inc"]       = np.log(df["median_hh_income"].clip(lower=1))
    df["log_population"]       = np.log(df["total_population"].clip(lower=1))
    df["share_white_nh"]       = df["pop_white_non_hispanic"] / df["total_population"]
    df["share_hispanic"]       = df["pop_hispanic_any_race"]  / df["total_population"]
    df["share_black"]          = df["pop_black_non_hispanic"] / df["total_population"]
    df["share_owner_occupied"] = (df["housing_units_owner_occupied"]
                                  / df["housing_units_total"])
    df["share_drove_alone"]    = df["commuters_drove_alone"] / df["commuters_total"]
    keep = ["fips", "median_hh_income", "total_population",
            "log_med_hh_inc", "log_population", "share_under_150k",
            "share_white_nh", "share_hispanic", "share_black",
            "share_owner_occupied", "share_drove_alone"]
    return df[keep]


def load_state_gasoline_cdtfa() -> pd.DataFrame:
    """CDTFA fuel-tax statistics (state-level). Convert fiscal year to
    calendar year by 50/50-averaging adjacent fiscal-year rows that
    straddle the calendar year."""
    f = GAS_DIR / "fuel_tax_stats.csv"
    df = _read_csv(f)
    df = df.rename(columns={
        "Fiscal Year From":  "fy_from",
        "Fiscal Year To":    "fy_to",
        "Gasoline Taxable Distributions (Gallons)": "gallons",
    })
    df["fy_from"] = pd.to_numeric(df["fy_from"], errors="coerce")
    df["fy_to"]   = pd.to_numeric(df["fy_to"],   errors="coerce")
    df["gallons"] = pd.to_numeric(df["gallons"], errors="coerce")
    rows = []
    for y in YEARS:
        a = df.loc[df["fy_to"]   == y, "gallons"]
        b = df.loc[df["fy_from"] == y, "gallons"]
        a_v = a.iloc[0] if len(a) else np.nan
        b_v = b.iloc[0] if len(b) else np.nan
        if np.isnan(a_v) and np.isnan(b_v):
            val = np.nan
        elif np.isnan(a_v):
            val = b_v
        elif np.isnan(b_v):
            val = a_v
        else:
            val = 0.5 * a_v + 0.5 * b_v
        rows.append({"year_id": y, "state_gallons": val})
    return pd.DataFrame(rows)


def allocate_gasoline_to_counties(state_gas, acs, counties) -> pd.DataFrame:
    pop = acs[["fips", "total_population"]].copy()
    pop["pop_share"] = pop["total_population"] / pop["total_population"].sum()
    grid = counties[["fips"]].merge(state_gas, how="cross")
    out = grid.merge(pop[["fips", "pop_share"]], on="fips", how="left")
    out["gasoline_gallons"] = out["state_gallons"] * out["pop_share"]
    return out[["fips", "year_id", "gasoline_gallons"]]


def load_aqi_county() -> pd.DataFrame:
    frames = []
    for y in YEARS:
        f = AQ_DIR / f"annual_aqi_by_county_{y}.csv"
        if not f.exists():
            continue
        df = _read_csv(f)
        df = df[df["State"] == "California"].copy()
        df = df.rename(columns={"County": "county_name",
                                "Year": "year_id",
                                "Median AQI": "median_aqi",
                                "90th Percentile AQI": "p90_aqi",
                                "Max AQI": "max_aqi",
                                "Days PM2.5": "days_pm25",
                                "Days Ozone": "days_ozone"})
        frames.append(df[["county_name", "year_id", "median_aqi",
                          "p90_aqi", "max_aqi",
                          "days_pm25", "days_ozone"]])
    if not frames:
        return pd.DataFrame(columns=["county_name", "year_id", "median_aqi",
                                     "p90_aqi", "max_aqi",
                                     "days_pm25", "days_ozone"])
    return pd.concat(frames, ignore_index=True)


def load_aqs_pollutants():
    pm_rows, o3_rows = [], []
    for y in YEARS:
        f = AQ_DIR / f"annual_conc_by_monitor_{y}.csv"
        if not f.exists():
            continue
        df = _read_csv(f)
        df = df[df["State Code"].astype(str).str.zfill(2) == "06"].copy()
        df["fips"] = ("06" + df["County Code"].astype(str).str.zfill(3))
        pm = df[(df["Parameter Code"] == 88101)
                & (df["Sample Duration"].astype(str).str.startswith("24-HR"))
                & (df["Observation Percent"] >= 75)]
        if len(pm):
            agg = (pm.groupby("fips", as_index=False)
                     .agg(pm25_annual_ugm3=("Arithmetic Mean", "mean"),
                          n_pm_monitors=("Arithmetic Mean", "count")))
            agg["year_id"] = y
            pm_rows.append(agg)
        oz = df[(df["Parameter Code"] == 44201)
                & (df["Sample Duration"].astype(str).str.contains("8-HR"))
                & (df["Observation Percent"] >= 75)]
        if len(oz):
            agg = (oz.groupby("fips", as_index=False)
                     .agg(o3_dv_ppm=("4th Max Value", "mean"),
                          n_o3_monitors=("4th Max Value", "count")))
            agg["year_id"] = y
            o3_rows.append(agg)
    pm_df = (pd.concat(pm_rows, ignore_index=True) if pm_rows
             else pd.DataFrame(columns=["fips", "year_id",
                                        "pm25_annual_ugm3"]))
    o3_df = (pd.concat(o3_rows, ignore_index=True) if o3_rows
             else pd.DataFrame(columns=["fips", "year_id", "o3_dv_ppm"]))
    return pm_df, o3_df


def load_rucc() -> pd.DataFrame:
    f = RUR_DIR / "rural_classification.csv"
    df = pd.read_csv(f, encoding="latin-1", dtype={"FIPS": str},
                     low_memory=False)
    df = df[(df["State"] == "CA") & (df["Attribute"] == "RUCC_2023")].copy()
    df["fips"]      = df["FIPS"].astype(str).str.zfill(5)
    df["rucc_code"] = pd.to_numeric(df["Value"], errors="coerce")
    return df[["fips", "rucc_code"]]


def load_zev_share(stations: pd.DataFrame) -> pd.DataFrame:
    f = ZEV_DIR / "vehicle_fuel_type_counts_2025.csv"
    if not f.exists():
        return pd.DataFrame(columns=["fips", "year_id", "zev_share",
                                     "zev_count", "total_vehicles"])
    df = _read_csv(f)
    df = df[df["Duty"] == "Light"].copy()
    df["zip"] = df["ZIP Code"].astype(str).str.extract(r"(\d{5})")[0]
    df["is_zev"] = df["Fuel"].isin(["Battery Electric",
                                     "Plug-in Hybrid",
                                     "Hydrogen Fuel Cell"]).astype(int)

    # ZIP -> county via majority rule from EV-station ZIPs (mirrors SQL)
    z = (stations.dropna(subset=["zip"])
                 .groupby(["zip", "fips"]).size().reset_index(name="n"))
    z["rk"] = z.groupby("zip")["n"].rank("first", ascending=False)
    z = z[z["rk"] == 1][["zip", "fips"]]
    df = df.merge(z, on="zip", how="left").dropna(subset=["fips"])
    df["year_id"] = 2025
    grp = (df.assign(zev_n=df["is_zev"] * df["Vehicles"],
                     tot_n=df["Vehicles"])
             .groupby(["fips", "year_id"], as_index=False)
             [["zev_n", "tot_n"]].sum()
             .rename(columns={"zev_n": "zev_count",
                              "tot_n": "total_vehicles"}))
    grp["zev_share"] = grp["zev_count"] / grp["total_vehicles"].replace(0, np.nan)
    return grp[["fips", "year_id", "zev_share", "zev_count", "total_vehicles"]]


def assemble_panel(counties, ev_cy, acs, gas, aqi, pm25, o3, rucc, zev):
    grid = (counties[["fips", "county_name", "centroid_lat", "centroid_lon"]]
            .merge(pd.DataFrame({"year_id": YEARS}), how="cross"))
    grid["post_nevi"]    = (grid["year_id"] >= 2022).astype(int)
    grid["post_obbba"]   = (grid["year_id"] >= 2026).astype(int)
    grid["obbba_weight"] = np.where(grid["year_id"] == 2025, 92.0/365.0,
                            np.where(grid["year_id"] >= 2026, 1.0, 0.0))

    cum2021 = (ev_cy[ev_cy["year_id"] == 2021]
               [["fips", "dcfc_cum", "l2_cum"]]
               .rename(columns={"dcfc_cum": "dcfc_2021",
                                "l2_cum":   "l2_2021"}))
    pop = acs[["fips", "total_population"]]
    dose = pop.merge(cum2021, on="fips", how="left").fillna(
        {"dcfc_2021": 0, "l2_2021": 0})
    dose["dose_dcfc_pc"] = dose["dcfc_2021"] / (dose["total_population"] / 10000.0)
    dose["dose_l2_pc"]   = dose["l2_2021"]   / (dose["total_population"] / 10000.0)
    denom = (dose["dcfc_2021"] + dose["l2_2021"]).replace(0, np.nan)
    dose["share_dcfc"]   = dose["dcfc_2021"] / denom
    p01, p99 = dose["dose_dcfc_pc"].quantile([0.01, 0.99])
    dose["dose_dcfc_pc"] = dose["dose_dcfc_pc"].clip(lower=p01, upper=p99)

    aqi_match = aqi.merge(counties[["fips", "county_name"]],
                          on="county_name", how="inner").drop(columns=["county_name"])

    panel = (grid
        .merge(gas,                 on=["fips", "year_id"], how="left")
        .merge(aqi_match,           on=["fips", "year_id"], how="left")
        .merge(pm25,                on=["fips", "year_id"], how="left")
        .merge(o3,                  on=["fips", "year_id"], how="left")
        .merge(acs,                 on="fips", how="left")
        .merge(rucc,                on="fips", how="left")
        .merge(zev,                 on=["fips", "year_id"], how="left")
        .merge(dose[["fips", "dose_dcfc_pc", "dose_l2_pc", "share_dcfc"]],
                                    on="fips", how="left")
    )
    panel["gasoline_pc"]     = panel["gasoline_gallons"] / panel["total_population"]
    panel["log_gasoline_pc"] = np.log(panel["gasoline_pc"].replace(0, np.nan))
    panel["log_pm25"]        = np.log(panel["pm25_annual_ugm3"].replace(0, np.nan))

    panel["dose_x_post_nevi"]    = panel["dose_dcfc_pc"]    * panel["post_nevi"]
    panel["dose_sq_x_post_nevi"] = (panel["dose_dcfc_pc"]**2) * panel["post_nevi"]
    panel["dose_x_post_obbba"]   = panel["dose_dcfc_pc"]    * panel["post_obbba"]
    panel["dose_x_post_obbba_w"] = panel["dose_dcfc_pc"]    * panel["obbba_weight"]

    panel = panel.sort_values(["fips", "year_id"]).reset_index(drop=True)
    return panel


def build_panel_from_csv() -> pd.DataFrame:
    print(f"[build] reading raw CSVs from {DATA_DIR}")
    counties = load_counties()
    print(f"[build] {len(counties)} CA counties loaded")
    stations = load_ev_stations(counties)
    print(f"[build] {len(stations)} EV stations geocoded to counties")
    ev_cy = build_ev_dose(counties, stations)
    acs   = load_acs()
    print(f"[build] ACS rows: {len(acs)}")
    state_gas = load_state_gasoline_cdtfa()
    gas = allocate_gasoline_to_counties(state_gas, acs, counties)
    aqi = load_aqi_county()
    print(f"[build] AQI rows: {len(aqi)}")
    pm25, o3 = load_aqs_pollutants()
    print(f"[build] PM2.5 rows: {len(pm25)} ; Ozone rows: {len(o3)}")
    rucc = load_rucc()
    zev  = load_zev_share(stations)
    panel = assemble_panel(counties, ev_cy, acs, gas, aqi, pm25, o3, rucc, zev)
    print(f"[build] panel shape: {panel.shape}")
    return panel


def get_panel() -> pd.DataFrame:
    df = try_load_from_sql()
    return df if df is not None else build_panel_from_csv()


# --------------------------------------------------------------------
# 3. TWFE estimation
# --------------------------------------------------------------------
def prepare(df: pd.DataFrame) -> pd.DataFrame:
    needed = [OUTCOME, "dose_dcfc_pc", "post_nevi", "post_obbba"] + COVARS
    n0 = len(df)
    df = df.dropna(subset=needed).copy()
    print(f"[prepare] kept {len(df)} of {n0} county-years across "
          f"{df[ENTITY_VAR].nunique()} counties")
    qs = pd.qcut(df["dose_dcfc_pc"], q=5, labels=False, duplicates="drop")
    for q in sorted(qs.dropna().unique()):
        df[f"dose_q{int(q)+1}_x_post_nevi"] = (qs == q).astype(int) * df["post_nevi"]
    return df.set_index([ENTITY_VAR, TIME_VAR])


def fit_twfe(df, dep, regressors, label=""):
    from linearmodels.panel import PanelOLS
    # Drop regressors that are constant or all-zero (unidentified after FE);
    # this typically applies to dose_x_post_obbba when the panel does not yet
    # span any post-2026 calendar year.
    rhs_cols = [c for c in regressors
                if df[c].astype(float).std(skipna=True) > 0]
    dropped  = [c for c in regressors if c not in rhs_cols]
    if dropped:
        print(f"[fit] {label}: dropping zero-variance regressors {dropped}")
    rhs = df[rhs_cols].astype(float).assign(const=1.0)
    res = PanelOLS(dependent=df[dep].astype(float), exog=rhs,
                   entity_effects=True, time_effects=True,
                   drop_absorbed=True, check_rank=False
        ).fit(cov_type="clustered", cluster_entity=True,
              cluster_time=False, group_debias=True)
    print(f"\n=== {label} ===")
    print(res.summary.tables[0])
    return res


def collect_row(res, model_id, model_name, focal):
    if focal not in res.params.index:
        return None
    ci = res.conf_int().loc[focal]
    return dict(
        model_id=model_id, model_name=model_name, regressor=focal,
        estimate=float(res.params[focal]),
        std_error=float(res.std_errors[focal]),
        t_stat=float(res.tstats[focal]),
        p_value=float(res.pvalues[focal]),
        ci_lower=float(ci["lower"]), ci_upper=float(ci["upper"]),
        n_obs=int(res.nobs),
        rsq_within=float(res.rsquared_within),
        rsq_overall=float(res.rsquared_overall),
    )


def run_models(df) -> pd.DataFrame:
    rows = []
    m1 = fit_twfe(df, OUTCOME, ["dose_x_post_nevi"] + COVARS,
                  "M1: linear dose x Post_NEVI")
    rows.append(collect_row(m1, "M1", "Linear dose x Post_NEVI",
                            "dose_x_post_nevi"))
    m2 = fit_twfe(df, OUTCOME,
                  ["dose_x_post_nevi", "dose_sq_x_post_nevi"] + COVARS,
                  "M2: quadratic dose")
    rows.append(collect_row(m2, "M2", "Linear (in quadratic spec)",
                            "dose_x_post_nevi"))
    rows.append(collect_row(m2, "M2", "Quadratic",
                            "dose_sq_x_post_nevi"))
    bin_cols = sorted(c for c in df.columns
                      if c.startswith("dose_q") and c.endswith("_x_post_nevi"))
    bin_in = bin_cols[1:]                          # q1 is the reference
    if bin_in:
        m3 = fit_twfe(df, OUTCOME, bin_in + COVARS,
                      "M3: quintile bins of dose x Post_NEVI")
        for b in bin_in:
            rows.append(collect_row(m3, "M3", f"Bin {b}", b))
    m4 = fit_twfe(df, OUTCOME,
                  ["dose_x_post_nevi", "dose_x_post_obbba"] + COVARS,
                  "M4: Post_NEVI + Post_OBBBA")
    rows.append(collect_row(m4, "M4", "Dose x Post_NEVI",  "dose_x_post_nevi"))
    rows.append(collect_row(m4, "M4", "Dose x Post_OBBBA", "dose_x_post_obbba"))
    return pd.DataFrame([r for r in rows if r is not None])


def event_study(df, window=(-6, 3)) -> pd.DataFrame:
    es = df.reset_index().copy()
    leads_lags = []
    for k in range(window[0], window[1] + 1):
        if k == -1:
            continue
        col = f"k_{'m' if k < 0 else 'p'}{abs(k)}"
        es[col] = ((es["year_id"] - 2022) == k).astype(int) * es["dose_dcfc_pc"]
        leads_lags.append((k, col))
    es = es.set_index([ENTITY_VAR, TIME_VAR])
    regressors = [c for _, c in leads_lags] + COVARS
    res = fit_twfe(es, OUTCOME, regressors,
                   f"M5: event study, k in {window} (ref k = -1)")
    rows = []
    for k, col in leads_lags:
        if col not in res.params.index:
            continue
        ci = res.conf_int().loc[col]
        rows.append(dict(event_time=k,
                         estimate=float(res.params[col]),
                         std_error=float(res.std_errors[col]),
                         ci_lower=float(ci["lower"]),
                         ci_upper=float(ci["upper"])))
    return pd.DataFrame(rows).sort_values("event_time")


def plot_event_study(es_df, out_png):
    try:
        import matplotlib
        matplotlib.use("Agg")
        import matplotlib.pyplot as plt
    except ImportError:
        print("[plot] matplotlib not available; skipping plot")
        return
    fig, ax = plt.subplots(figsize=(8, 4.5))
    ax.axhline(0, color="grey", lw=0.8)
    ax.axvline(0, color="red",  lw=0.8, ls="--", label="NEVI 2022")
    ax.errorbar(es_df["event_time"], es_df["estimate"],
                yerr=[es_df["estimate"] - es_df["ci_lower"],
                      es_df["ci_upper"] - es_df["estimate"]],
                fmt="o", capsize=4, color="#1F3864")
    ax.set_xlabel("Years relative to 2022 (NEVI)")
    ax.set_ylabel(r"$\theta_k$ on dose x event-time")
    ax.set_title("Event-study TWFE: dose effect on log gasoline per capita")
    fig.tight_layout()
    fig.savefig(out_png, dpi=160)
    print(f"[plot] wrote {out_png}")


def main():
    panel = get_panel()
    panel_csv = OUT_DIR / "panel_for_r.csv"
    panel.to_csv(panel_csv, index=False, float_format="%.8g")
    print(f"[write] {panel_csv}")

    df = prepare(panel)
    results = run_models(df)
    out_csv = OUT_DIR / "twfe_results_python.csv"
    results.to_csv(out_csv, index=False, float_format="%.8g")
    print(f"[write] {out_csv}")

    es = event_study(df)
    es_csv = OUT_DIR / "twfe_event_study_python.csv"
    es.to_csv(es_csv, index=False, float_format="%.8g")
    print(f"[write] {es_csv}")

    plot_event_study(es, OUT_DIR / "twfe_event_study.png")
    print("\n[done] All artifacts written to", OUT_DIR)


if __name__ == "__main__":
    sys.exit(main())
