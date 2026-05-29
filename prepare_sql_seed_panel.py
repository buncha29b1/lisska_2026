"""Create the root-level SQL seed panel without third-party packages.

This helper reads the collected repo data with Python's standard library and
writes ca_county_year_panel_sql_seed.csv. The SSMS preprocessing script embeds
the current committed seed as T-SQL INSERT statements instead of using BULK
INSERT/OPENROWSET, which avoids OLE DB provider errors on locked-down SQL Server
installations.
"""
from __future__ import annotations

import csv
import sys
import math
from collections import defaultdict
from pathlib import Path

ROOT = Path(__file__).resolve().parent
DATA = ROOT / "data"
YEARS = range(2010, 2026)
OUT = ROOT / "ca_county_year_panel_sql_seed.csv"
csv.field_size_limit(sys.maxsize)


def fnum(value: object) -> float | None:
    text = str(value).replace(",", "").strip()
    if text == "":
        return None
    try:
        return float(text)
    except ValueError:
        return None


def clean_county(value: object) -> str:
    text = str(value).strip()
    for suffix in (", California", " County"):
        if text.lower().endswith(suffix.lower()):
            text = text[: -len(suffix)]
    return " ".join(text.split()).upper()


def read_csv(path: Path):
    with path.open(newline="", encoding="utf-8-sig", errors="replace") as fh:
        yield from csv.DictReader(fh)


def nearest_fips(lat: float, lon: float, counties: list[dict[str, object]]) -> str:
    best = None
    best_dist = float("inf")
    for row in counties:
        clat = row["county_lat"]
        clon = row["county_lon"]
        if clat is None or clon is None:
            continue
        dist = (lat - clat) ** 2 + (lon - clon) ** 2
        if dist < best_dist:
            best_dist = dist
            best = row["fips"]
    return str(best) if best is not None else ""


def weighted_mean(rows: list[tuple[float, float]]) -> float | None:
    rows = [(v, w) for v, w in rows if v is not None]
    if not rows:
        return None
    denom = sum(max(w or 1.0, 1.0) for _, w in rows)
    return sum(v * max(w or 1.0, 1.0) for v, w in rows) / denom if denom else None


def main() -> None:
    counties = []
    for row in read_csv(DATA / "county_spatial_data" / "ca_counties.csv"):
        counties.append(
            {
                "fips": str(row["GEOID"]).zfill(5),
                "county": row["NAME"].replace(",", " "),
                "county_key": clean_county(row["NAME"]),
                "aland": fnum(row["ALAND"]),
                "county_lat": fnum(row["INTPTLAT"]),
                "county_lon": fnum(row["INTPTLON"]),
            }
        )
    counties.sort(key=lambda r: r["fips"])
    counties_by_fips = {r["fips"]: r for r in counties}

    acs = {}
    for row in read_csv(DATA / "sociodemographic" / "census_acs_county_data.csv"):
        fips = str(row["state_fips"]).zfill(2) + str(row["county_fips"]).zfill(3)
        if not fips.startswith("06"):
            continue
        total_pop = fnum(row["total_population"])
        med_inc = fnum(row["median_hh_income"])
        white = fnum(row["pop_white_non_hispanic"])
        hu = fnum(row["housing_units_total"])
        owner = fnum(row["housing_units_owner_occupied"])
        commuters = fnum(row["commuters_total"])
        alone = fnum(row["commuters_drove_alone"])
        acs[fips] = {
            "median_hh_income": med_inc,
            "total_population": total_pop,
            "share_under_150k": fnum(row["share_under_150k"]),
            "log_med_hh_inc": math.log(med_inc) if med_inc and med_inc > 0 else None,
            "log_population": math.log(total_pop) if total_pop and total_pop > 0 else None,
            "share_white_nh": white / total_pop if white is not None and total_pop else None,
            "share_owner_occupied": owner / hu if owner is not None and hu else None,
            "share_commute_alone": alone / commuters if alone is not None and commuters else None,
        }

    rural = {}
    for row in read_csv(DATA / "rurality_classification" / "rural_classification.csv"):
        if row["State"] == "CA" and row["Attribute"] == "RUCC_2023":
            rural[str(row["FIPS"]).zfill(5)] = fnum(row["Value"])

    gas = {}
    for row in read_csv(ROOT / "ca_cec_county_gasoline_long.csv"):
        if clean_county(row["county"]) == "TOTAL":
            continue
        gas[(clean_county(row["county"]), int(row["year"]))] = fnum(row["gasoline_gallons"])

    eia = {}
    for row in read_csv(DATA / "gasoline_consumption" / "eia_seds_gasoline_ca.csv"):
        eia[int(row["period"])] = {
            "gasoline_price_dollars_per_mmbtu": fnum(row["value"]),
            "eia_gasoline_gallons": fnum(row["gallons"]),
        }

    pm25_raw = defaultdict(list)
    o3_raw = defaultdict(list)
    for year in YEARS:
        path = DATA / "air_quality" / f"annual_conc_by_monitor_{year}.csv"
        for row in read_csv(path):
            if str(row["State Code"]).zfill(2) != "06":
                continue
            fips = str(row["State Code"]).zfill(2) + str(row["County Code"]).zfill(3)
            param = row["Parameter Code"]
            duration = row["Sample Duration"].upper()
            weight = fnum(row["Observation Count"]) or 1.0
            if param == "88101" and "24" in duration:
                pm25_raw[(fips, year)].append((fnum(row["Arithmetic Mean"]), weight))
            elif param == "44201" and "8-HR" in duration:
                o3_raw[(fips, year)].append((fnum(row["4th Max Value"]), weight))
    air = {}
    for key, rows in pm25_raw.items():
        air.setdefault(key, {})["pm25"] = weighted_mean(rows)
    for key, rows in o3_raw.items():
        air.setdefault(key, {})["o3"] = weighted_mean(rows)

    ev_counts = defaultdict(lambda: {"dcfc": 0.0, "l2": 0.0})
    for row in read_csv(DATA / "ev_charging_infrastructure" / "ev_charging_stations_ca.csv"):
        if row.get("state") != "CA":
            continue
        open_date = row.get("open_date", "")
        if not open_date or open_date > "2021-12-31":
            continue
        lat = fnum(row.get("latitude"))
        lon = fnum(row.get("longitude"))
        if lat is None or lon is None:
            continue
        fips = nearest_fips(lat, lon, counties)
        ev_counts[fips]["dcfc"] += fnum(row.get("ev_dc_fast_num")) or 0.0
        ev_counts[fips]["l2"] += fnum(row.get("ev_level2_evse_num")) or 0.0

    densities = []
    dose_base = {}
    for fips in counties_by_fips:
        pop = acs.get(fips, {}).get("total_population")
        dcfc = ev_counts[fips]["dcfc"]
        l2 = ev_counts[fips]["l2"]
        density = dcfc / (pop / 10000.0) if pop else None
        dose_base[fips] = {"dcfc": dcfc, "l2": l2, "density": density}
        if density is not None:
            densities.append(density)
    densities.sort()

    def pct(values: list[float], q: float) -> float:
        if not values:
            return 0.0
        pos = (len(values) - 1) * q
        lo = math.floor(pos)
        hi = math.ceil(pos)
        if lo == hi:
            return values[lo]
        return values[lo] * (hi - pos) + values[hi] * (pos - lo)

    p01 = pct(densities, 0.01)
    p99 = pct(densities, 0.99)

    fields = [
        "fips",
        "county",
        "aland",
        "year",
        "gasoline_gallons",
        "gasoline_pc",
        "log_gasoline_pc",
        "pm25",
        "log_pm25",
        "o3",
        "log_o3",
        "dcfc_ports_2021",
        "l2_ports_2021",
        "dose_dcfc_density",
        "dose_dcfc_density_sq",
        "ihs_dose_dcfc_density",
        "share_dcfc_2021",
        "post_nevi",
        "post_obbba",
        "dose_x_post_nevi",
        "dose_sq_x_post_nevi",
        "dose_x_post_obbba",
        "median_hh_income",
        "total_population",
        "share_under_150k",
        "log_med_hh_inc",
        "log_population",
        "share_white_nh",
        "share_owner_occupied",
        "share_commute_alone",
        "rucc_2023",
        "gasoline_price_dollars_per_mmbtu",
        "eia_gasoline_gallons",
    ]

    def outval(value: object) -> object:
        if value is None:
            return ""
        if isinstance(value, float):
            if math.isnan(value) or math.isinf(value):
                return ""
            return f"{value:.12g}"
        return value

    with OUT.open("w", newline="", encoding="utf-8") as fh:
        writer = csv.DictWriter(fh, fieldnames=fields, lineterminator="\n")
        writer.writeheader()
        for c in counties:
            fips = c["fips"]
            a = acs.get(fips, {})
            d = dose_base[fips]
            density = d["density"]
            dose = min(max(density if density is not None else 0.0, p01), p99)
            denom = d["dcfc"] + d["l2"]
            for year in YEARS:
                g = gas.get((c["county_key"], year))
                pop = a.get("total_population")
                gas_pc = g / pop if g is not None and pop else None
                aq = air.get((fips, year), {})
                pm25 = aq.get("pm25")
                o3 = aq.get("o3")
                post_nevi = 1 if year >= 2022 else 0
                post_obbba = 1 if year >= 2026 else 0
                row = {
                    "fips": fips,
                    "county": c["county"],
                    "aland": c["aland"],
                    "year": year,
                    "gasoline_gallons": g,
                    "gasoline_pc": gas_pc,
                    "log_gasoline_pc": math.log1p(gas_pc) if gas_pc is not None else None,
                    "pm25": pm25,
                    "log_pm25": math.log1p(pm25) if pm25 is not None else None,
                    "o3": o3,
                    "log_o3": math.log1p(o3) if o3 is not None else None,
                    "dcfc_ports_2021": d["dcfc"],
                    "l2_ports_2021": d["l2"],
                    "dose_dcfc_density": dose,
                    "dose_dcfc_density_sq": dose * dose,
                    "ihs_dose_dcfc_density": math.asinh(dose),
                    "share_dcfc_2021": d["dcfc"] / denom if denom else None,
                    "post_nevi": post_nevi,
                    "post_obbba": post_obbba,
                    "dose_x_post_nevi": dose * post_nevi,
                    "dose_sq_x_post_nevi": dose * dose * post_nevi,
                    "dose_x_post_obbba": dose * post_obbba,
                    **a,
                    "rucc_2023": rural.get(fips),
                    **eia.get(year, {}),
                }
                writer.writerow({field: outval(row.get(field)) for field in fields})
    print(f"Wrote {OUT} with {len(counties) * len(list(YEARS))} rows")


if __name__ == "__main__":
    main()
