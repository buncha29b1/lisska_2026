"""Build the California county-year TWFE panel and estimate baseline models.

Run from the repository root:
    python build_twfe_model.py

To estimate on the clean dataset exported from preprocess_twfe_sqlserver.sql:
    python build_twfe_model.py --panel-input ca_county_year_panel.csv

Inputs are read from ./data unless --panel-input or --sql-connection is used.
Outputs are written to the repository root so code files and clean model artifacts
remain outside the data folders.
"""
from __future__ import annotations

import argparse
import json
import math
import re
import sys
import warnings
from pathlib import Path

import numpy as np
import pandas as pd

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
YEARS = list(range(2010, 2026))
POLICY_YEAR_NEVI = 2022
POLICY_YEAR_OBBBA = 2026
PANEL_CSV = ROOT / "ca_county_year_panel.csv"
PANEL_PARQUET = ROOT / "ca_county_year_panel.parquet"
PY_RESULTS_CSV = ROOT / "twfe_python_results.csv"
DIAGNOSTICS_JSON = ROOT / "twfe_panel_diagnostics.json"
SQL_PANEL_CSV = ROOT / "ca_county_year_panel_from_sql.csv"


def clean_county_name(value: object) -> str:
    """Normalize county names for joins while preserving exact source fields."""
    if pd.isna(value):
        return ""
    text = str(value).strip()
    text = re.sub(r",\s*California$", "", text, flags=re.I)
    text = re.sub(r"\s+County$", "", text, flags=re.I)
    return re.sub(r"\s+", " ", text).strip().upper()


def to_num(series: pd.Series) -> pd.Series:
    return pd.to_numeric(series.astype(str).str.replace(",", "", regex=False).str.strip(), errors="coerce")


def load_counties() -> pd.DataFrame:
    path = DATA / "county_spatial_data" / "ca_counties.csv"
    counties = pd.read_csv(path, dtype={"STATEFP": str, "COUNTYFP": str, "GEOID": str})
    counties = counties.rename(
        columns={"GEOID": "fips", "NAME": "county", "ALAND": "aland", "INTPTLAT": "county_lat", "INTPTLON": "county_lon"}
    )
    counties["fips"] = counties["fips"].str.zfill(5)
    counties["county_key"] = counties["county"].map(clean_county_name)
    counties["aland"] = to_num(counties["aland"])
    counties["county_lat"] = to_num(counties["county_lat"])
    counties["county_lon"] = to_num(counties["county_lon"])
    keep = ["fips", "county", "county_key", "aland", "county_lat", "county_lon", "geometry"]
    return counties[keep].sort_values("fips").reset_index(drop=True)


def build_skeleton(counties: pd.DataFrame) -> pd.DataFrame:
    years = pd.DataFrame({"year": YEARS})
    return counties.merge(years, how="cross")


def load_acs() -> pd.DataFrame:
    path = DATA / "sociodemographic" / "census_acs_county_data.csv"
    acs = pd.read_csv(path, dtype={"state_fips": str, "county_fips": str})
    acs["fips"] = acs["state_fips"].str.zfill(2) + acs["county_fips"].str.zfill(3)
    numeric = [
        "median_hh_income",
        "total_population",
        "pop_white_non_hispanic",
        "housing_units_total",
        "housing_units_owner_occupied",
        "commuters_total",
        "commuters_drove_alone",
        "share_under_150k",
    ]
    for col in numeric:
        acs[col] = to_num(acs[col])
    acs["log_med_hh_inc"] = np.log(acs["median_hh_income"].where(acs["median_hh_income"] > 0))
    acs["log_population"] = np.log(acs["total_population"].where(acs["total_population"] > 0))
    acs["share_white_nh"] = acs["pop_white_non_hispanic"] / acs["total_population"]
    acs["share_owner_occupied"] = acs["housing_units_owner_occupied"] / acs["housing_units_total"]
    acs["share_commute_alone"] = acs["commuters_drove_alone"] / acs["commuters_total"]
    keep = [
        "fips",
        "median_hh_income",
        "total_population",
        "share_under_150k",
        "log_med_hh_inc",
        "log_population",
        "share_white_nh",
        "share_owner_occupied",
        "share_commute_alone",
    ]
    return acs.loc[acs["fips"].str.startswith("06"), keep].drop_duplicates("fips")


def load_rurality() -> pd.DataFrame:
    path = DATA / "rurality_classification" / "rural_classification.csv"
    rural = pd.read_csv(path, dtype={"FIPS": str})
    rural = rural.loc[(rural["State"] == "CA") & (rural["Attribute"].eq("RUCC_2023"))].copy()
    rural["fips"] = rural["FIPS"].str.zfill(5)
    rural["rucc_2023"] = to_num(rural["Value"]).astype("Int64")
    return rural[["fips", "rucc_2023"]]


def load_gasoline_from_cec() -> pd.DataFrame:
    path = DATA / "gasoline_consumption" / "cec_a15_county_gasoline.xlsx"
    raw = pd.read_excel(path, sheet_name="Retail Gasoline Sales by County", header=None)
    year_row = raw.iloc[2].ffill()
    measure_row = raw.iloc[3]
    data = raw.iloc[4:].copy()
    data = data.loc[data.iloc[:, 0].notna()]
    rows = []
    for idx in range(1, raw.shape[1]):
        year_text = str(year_row.iloc[idx])
        match = re.search(r"(20\d{2})", year_text)
        if not match:
            continue
        measure = str(measure_row.iloc[idx]).strip().lower()
        if measure not in {"estimated totals", "estimated"}:
            continue
        tmp = pd.DataFrame({"county_key": data.iloc[:, 0].map(clean_county_name), "year": int(match.group(1)), "gasoline_million_gallons": to_num(data.iloc[:, idx])})
        rows.append(tmp)
    gas = pd.concat(rows, ignore_index=True)
    gas = gas.groupby(["county_key", "year"], as_index=False)["gasoline_million_gallons"].first()
    gas["gasoline_gallons"] = gas["gasoline_million_gallons"] * 1_000_000
    return gas


def load_eia_seds() -> pd.DataFrame:
    path = DATA / "gasoline_consumption" / "eia_seds_gasoline_ca.csv"
    eia = pd.read_csv(path)
    eia["year"] = to_num(eia["period"]).astype("Int64")
    eia["eia_gasoline_gallons"] = to_num(eia["gallons"])
    eia["gasoline_price_dollars_per_mmbtu"] = to_num(eia["value"])
    return eia[["year", "eia_gasoline_gallons", "gasoline_price_dollars_per_mmbtu"]].drop_duplicates("year")


def load_air_quality() -> pd.DataFrame:
    pm25_frames: list[pd.DataFrame] = []
    o3_frames: list[pd.DataFrame] = []
    for path in sorted((DATA / "air_quality").glob("annual_conc_by_monitor_*.csv")):
        usecols = [
            "State Code",
            "County Code",
            "Parameter Code",
            "Sample Duration",
            "Metric Used",
            "Year",
            "Arithmetic Mean",
            "4th Max Value",
            "Observation Count",
        ]
        df = pd.read_csv(path, usecols=usecols, dtype={"State Code": str, "County Code": str})
        df = df.loc[df["State Code"].str.zfill(2).eq("06")].copy()
        df["fips"] = df["State Code"].str.zfill(2) + df["County Code"].str.zfill(3)
        df["year"] = to_num(df["Year"]).astype(int)
        df["obs_weight"] = to_num(df["Observation Count"]).fillna(1).clip(lower=1)
        df["Arithmetic Mean"] = to_num(df["Arithmetic Mean"])
        df["4th Max Value"] = to_num(df["4th Max Value"])
        pm25 = df.loc[(df["Parameter Code"].eq(88101)) & (df["Sample Duration"].astype(str).str.contains("24", case=False, na=False))]
        if not pm25.empty:
            tmp = pm25.groupby(["fips", "year"]).apply(
                lambda x: np.average(x.loc[x["Arithmetic Mean"].notna(), "Arithmetic Mean"], weights=x.loc[x["Arithmetic Mean"].notna(), "obs_weight"])
                if x["Arithmetic Mean"].notna().any()
                else np.nan
            ).rename("pm25").reset_index()
            pm25_frames.append(tmp)
        o3 = df.loc[(df["Parameter Code"].eq(44201)) & (df["Sample Duration"].astype(str).str.contains("8-HR", case=False, na=False))]
        if not o3.empty:
            tmp = o3.groupby(["fips", "year"]).apply(
                lambda x: np.average(x.loc[x["4th Max Value"].notna(), "4th Max Value"], weights=x.loc[x["4th Max Value"].notna(), "obs_weight"])
                if x["4th Max Value"].notna().any()
                else np.nan
            ).rename("o3").reset_index()
            o3_frames.append(tmp)
    pm25_out = pd.concat(pm25_frames, ignore_index=True) if pm25_frames else pd.DataFrame(columns=["fips", "year", "pm25"])
    o3_out = pd.concat(o3_frames, ignore_index=True) if o3_frames else pd.DataFrame(columns=["fips", "year", "o3"])
    return pm25_out.merge(o3_out, on=["fips", "year"], how="outer").groupby(["fips", "year"], as_index=False).first()

def assign_station_counties(stations: pd.DataFrame, counties: pd.DataFrame) -> pd.DataFrame:
    try:
        import geopandas as gpd

        county_gdf = gpd.GeoDataFrame(counties.copy(), geometry=gpd.GeoSeries.from_wkt(counties["geometry"], crs="EPSG:4326"))
        station_gdf = gpd.GeoDataFrame(stations.copy(), geometry=gpd.points_from_xy(stations["longitude"], stations["latitude"], crs="EPSG:4326"))
        joined = gpd.sjoin(station_gdf, county_gdf[["fips", "geometry"]], predicate="within", how="left")
        return pd.DataFrame(joined.drop(columns=["geometry", "index_right"], errors="ignore"))
    except Exception as exc:  # pragma: no cover - fallback for minimal Python environments
        warnings.warn(f"geopandas spatial join failed ({exc}); assigning stations to nearest county centroid.")
        stations = stations.copy()
        county_coords = counties[["fips", "county_lat", "county_lon"]].dropna()
        def nearest(row: pd.Series) -> str | float:
            d2 = (county_coords["county_lat"] - row["latitude"]) ** 2 + (county_coords["county_lon"] - row["longitude"]) ** 2
            return county_coords.loc[d2.idxmin(), "fips"] if d2.notna().any() else np.nan
        stations["fips"] = stations.apply(nearest, axis=1)
        return stations


def load_ev_dose(counties: pd.DataFrame, acs: pd.DataFrame) -> pd.DataFrame:
    path = DATA / "ev_charging_infrastructure" / "ev_charging_stations_ca.csv"
    ev = pd.read_csv(path, low_memory=False)
    ev["open_date"] = pd.to_datetime(ev["open_date"], errors="coerce")
    ev["latitude"] = to_num(ev["latitude"])
    ev["longitude"] = to_num(ev["longitude"])
    ev["ev_dc_fast_num"] = to_num(ev["ev_dc_fast_num"]).fillna(0)
    ev["ev_level2_evse_num"] = to_num(ev["ev_level2_evse_num"]).fillna(0)
    ev = ev.loc[ev["state"].eq("CA") & ev["latitude"].notna() & ev["longitude"].notna()].copy()
    ev = assign_station_counties(ev, counties)
    pretreat = ev.loc[ev["open_date"].le(pd.Timestamp("2021-12-31"))].copy()
    dose = pretreat.groupby("fips", as_index=False).agg(dcfc_ports_2021=("ev_dc_fast_num", "sum"), l2_ports_2021=("ev_level2_evse_num", "sum"))
    dose = counties[["fips", "aland"]].merge(dose, on="fips", how="left").fillna({"dcfc_ports_2021": 0, "l2_ports_2021": 0})
    dose = dose.merge(acs[["fips", "total_population"]], on="fips", how="left")
    dose["dcfc_density_2021"] = dose["dcfc_ports_2021"] / (dose["total_population"] / 10_000)
    denom = dose["dcfc_ports_2021"] + dose["l2_ports_2021"]
    dose["share_dcfc_2021"] = np.where(denom > 0, dose["dcfc_ports_2021"] / denom, 0)
    q01, q99 = dose["dcfc_density_2021"].quantile([0.01, 0.99])
    dose["dose_dcfc_density"] = dose["dcfc_density_2021"].clip(q01, q99)
    dose["dose_dcfc_density_sq"] = dose["dose_dcfc_density"] ** 2
    dose["ihs_dose_dcfc_density"] = np.arcsinh(dose["dose_dcfc_density"])
    dose["nevi_corridor_km_per_sqkm"] = np.nan  # NEVI corridor GIS layer is not present in the collected data folder.
    return dose[["fips", "dcfc_ports_2021", "l2_ports_2021", "dcfc_density_2021", "dose_dcfc_density", "dose_dcfc_density_sq", "ihs_dose_dcfc_density", "share_dcfc_2021", "nevi_corridor_km_per_sqkm"]]


def load_zev_sales() -> pd.DataFrame:
    path = DATA / "zev_registrations_fleet_composition" / "new_zev_sales.xlsx"
    sales = pd.read_excel(path, sheet_name="County")
    sales["county_key"] = sales["COUNTY"].map(clean_county_name)
    sales["year"] = to_num(sales["Data Year"]).astype("Int64")
    sales["zev_new_sales"] = to_num(sales["Number of Vehicles"])
    return sales.groupby(["county_key", "year"], as_index=False)["zev_new_sales"].sum()


def assemble_panel() -> pd.DataFrame:
    counties = load_counties()
    acs = load_acs()
    panel = build_skeleton(counties)
    panel = panel.merge(acs, on="fips", how="left")
    panel = panel.merge(load_rurality(), on="fips", how="left")
    panel = panel.merge(load_gasoline_from_cec(), on=["county_key", "year"], how="left")
    panel = panel.merge(load_eia_seds(), on="year", how="left")
    panel = panel.merge(load_air_quality(), on=["fips", "year"], how="left")
    panel = panel.merge(load_ev_dose(counties, acs), on="fips", how="left")
    panel = panel.merge(load_zev_sales(), on=["county_key", "year"], how="left")

    panel["gasoline_pc"] = panel["gasoline_gallons"] / panel["total_population"]
    for col in ["gasoline_pc", "pm25", "o3"]:
        panel[f"log_{col}"] = np.log1p(panel[col])
    panel["post_nevi"] = (panel["year"] >= POLICY_YEAR_NEVI).astype(int)
    panel["post_obbba"] = (panel["year"] >= POLICY_YEAR_OBBBA).astype(int)
    panel["post_obbba_fractional_2025"] = np.where(panel["year"] > 2025, 1.0, np.where(panel["year"] == 2025, 92 / 365, 0.0))
    panel["dose_x_post_nevi"] = panel["dose_dcfc_density"] * panel["post_nevi"]
    panel["dose_sq_x_post_nevi"] = panel["dose_dcfc_density_sq"] * panel["post_nevi"]
    panel["ihs_dose_x_post_nevi"] = panel["ihs_dose_dcfc_density"] * panel["post_nevi"]
    panel["dose_x_post_obbba"] = panel["dose_dcfc_density"] * panel["post_obbba"]
    panel["dose_x_post_obbba_fractional_2025"] = panel["dose_dcfc_density"] * panel["post_obbba_fractional_2025"]
    panel["event_time_nevi"] = panel["year"] - POLICY_YEAR_NEVI
    for k in [-6, -5, -4, -3, -2, 0, 1, 2, 3]:
        panel[f"event_nevi_{k:+d}".replace("+", "plus").replace("-", "minus")] = panel["dose_dcfc_density"] * (panel["event_time_nevi"].eq(k)).astype(int)
    nonmissing_dose = panel.drop_duplicates("fips")[["fips", "dose_dcfc_density"]].dropna()
    nonmissing_dose["dose_quintile"] = pd.qcut(nonmissing_dose["dose_dcfc_density"].rank(method="first"), 5, labels=False) + 1
    panel = panel.merge(nonmissing_dose[["fips", "dose_quintile"]], on="fips", how="left")
    for q in range(1, 6):
        panel[f"dose_q{q}_x_post_nevi"] = (panel["dose_quintile"].eq(q) & panel["post_nevi"].eq(1)).astype(int)
    panel["msa_year_fe"] = panel["rucc_2023"].astype("string").fillna("missing") + "_" + panel["year"].astype(str)
    return panel.sort_values(["fips", "year"]).reset_index(drop=True)


def write_panel(panel: pd.DataFrame) -> None:
    panel.to_csv(PANEL_CSV, index=False)
    try:
        panel.to_parquet(PANEL_PARQUET, index=False)
    except Exception as exc:
        warnings.warn(f"Could not write parquet ({exc}); CSV output was written to {PANEL_CSV.name}.")
    cec_state = panel.groupby("year", as_index=False)["gasoline_gallons"].sum(min_count=1)
    eia = panel[["year", "eia_gasoline_gallons"]].drop_duplicates().dropna()
    diag = cec_state.merge(eia, on="year", how="inner")
    diag["pct_diff_cec_vs_eia"] = (diag["gasoline_gallons"] - diag["eia_gasoline_gallons"]) / diag["eia_gasoline_gallons"]
    diagnostics = {
        "rows": int(len(panel)),
        "counties": int(panel["fips"].nunique()),
        "years": [int(panel["year"].min()), int(panel["year"].max())],
        "obbba_note": "Annual panel ends in 2025, so Post_OBBBA is zero in all observed rows; use fractional 2025 robustness column until 2026 data arrive.",
        "gasoline_state_reconciliation": diag.to_dict(orient="records"),
        "missing_nevi_corridor_note": "No NEVI corridor GIS layer is present under data/, so nevi_corridor_km_per_sqkm is left null.",
    }
    DIAGNOSTICS_JSON.write_text(json.dumps(diagnostics, indent=2), encoding="utf-8")


def load_clean_panel(path: Path) -> pd.DataFrame:
    """Load a clean panel exported from SQL Server or produced by this script."""
    if not path.exists():
        raise FileNotFoundError(f"Clean panel file not found: {path}")
    if path.suffix.lower() == ".parquet":
        panel = pd.read_parquet(path)
    else:
        panel = pd.read_csv(path, dtype={"fips": str})
    if "fips" in panel.columns:
        panel["fips"] = panel["fips"].astype(str).str.zfill(5)
    if "year" in panel.columns:
        panel["year"] = to_num(panel["year"]).astype(int)
    return panel


def load_panel_from_sql(connection_string: str, table: str = "dbo.ca_county_year_panel") -> pd.DataFrame:
    """Load the SQL Server-generated clean panel directly with pyodbc."""
    try:
        import pyodbc
    except ImportError as exc:
        raise ImportError("Install pyodbc to use --sql-connection, or export the SQL result to CSV and pass --panel-input.") from exc
    query = f"SELECT * FROM {table} ORDER BY fips, [year]"
    with pyodbc.connect(connection_string) as conn:
        panel = pd.read_sql(query, conn)
    if "fips" in panel.columns:
        panel["fips"] = panel["fips"].astype(str).str.zfill(5)
    return panel


def fit_twfe(panel: pd.DataFrame, outcome: str = "log_gasoline_pc") -> pd.DataFrame:
    covariates = ["dose_x_post_nevi", "log_med_hh_inc", "share_under_150k", "share_white_nh", "log_population"]
    data = panel[["fips", "year", outcome, *covariates]].dropna().copy()
    results = []
    formula_rhs = "1 + " + " + ".join(covariates) + " + EntityEffects + TimeEffects"
    try:
        from linearmodels.panel import PanelOLS

        mod = PanelOLS.from_formula(
            f"{outcome} ~ {formula_rhs}",
            data=data.set_index(["fips", "year"]),
            drop_absorbed=True,
            check_rank=False,
        )
        res = mod.fit(cov_type="clustered", cluster_entity=True)
        for name in res.params.index:
            results.append({"model": "python_linearmodels_nevi", "term": name, "estimate": res.params[name], "std_error": res.std_errors[name], "p_value": res.pvalues[name], "nobs": int(res.nobs)})
    except Exception as exc:
        warnings.warn(f"linearmodels estimation failed ({exc}); falling back to statsmodels OLS with county/year dummies.")
        import statsmodels.formula.api as smf

        formula = f"{outcome} ~ " + " + ".join(covariates) + " + C(fips) + C(year)"
        res = smf.ols(formula, data=data).fit(cov_type="cluster", cov_kwds={"groups": data["fips"]})
        for name in covariates:
            results.append({"model": "python_statsmodels_nevi", "term": name, "estimate": res.params.get(name, np.nan), "std_error": res.bse.get(name, np.nan), "p_value": res.pvalues.get(name, np.nan), "nobs": int(res.nobs)})
    out = pd.DataFrame(results)
    out.to_csv(PY_RESULTS_CSV, index=False)
    return out


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Build or consume the clean county-year panel and estimate the TWFE model.")
    parser.add_argument(
        "--panel-input",
        type=Path,
        default=None,
        help="Use an existing clean panel CSV/parquet, such as the final result exported from preprocess_twfe_sqlserver.sql, instead of rebuilding from raw data.",
    )
    parser.add_argument(
        "--sql-connection",
        default=None,
        help="Optional pyodbc SQL Server connection string. When provided, the script reads dbo.ca_county_year_panel directly.",
    )
    parser.add_argument("--sql-table", default="dbo.ca_county_year_panel", help="SQL table/view to read with --sql-connection.")
    parser.add_argument("--outcome", default="log_gasoline_pc", help="Outcome column to estimate; default is log_gasoline_pc.")
    return parser.parse_args()


def main() -> int:
    args = parse_args()
    if args.sql_connection:
        panel = load_panel_from_sql(args.sql_connection, args.sql_table)
        panel.to_csv(SQL_PANEL_CSV, index=False)
        print(f"Loaded {len(panel):,} rows from {args.sql_table} and wrote {SQL_PANEL_CSV.name}.")
    elif args.panel_input is not None:
        panel = load_clean_panel(args.panel_input)
        print(f"Loaded clean panel {args.panel_input} with {len(panel):,} rows and {panel['fips'].nunique()} counties.")
    else:
        panel = assemble_panel()
        write_panel(panel)
        print(f"Wrote {PANEL_CSV.name} with {len(panel):,} rows and {panel['fips'].nunique()} counties.")
        if PANEL_PARQUET.exists():
            print(f"Wrote {PANEL_PARQUET.name}.")
    results = fit_twfe(panel, outcome=args.outcome)
    print(f"Wrote {PY_RESULTS_CSV.name}.")
    print(results.to_string(index=False))
    return 0


if __name__ == "__main__":
    sys.exit(main())
