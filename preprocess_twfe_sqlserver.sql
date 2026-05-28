/*
SQL Server preprocessing for the continuous-treatment TWFE panel.

Run this file in SQL Server Management Studio. SQLCMD Mode is NOT required.

IMPORTANT: SQL Server cannot infer the folder that contains an SSMS query file.
Before running, set @RepoRoot below to the absolute path of this repository on
 the SQL Server machine, for example:
  N'C:\Users\YourName\Documents\lisska_2026'

This script intentionally avoids OPENROWSET/Ad Hoc Distributed Queries. The CEC
Excel workbook has been converted once into the root-level helper CSV
ca_cec_county_gasoline_long.csv, so the script works on locked-down SQL Server
installations where OPENROWSET is disabled.
*/

SET NOCOUNT ON;

DROP TABLE IF EXISTS #twfe_config;
CREATE TABLE #twfe_config (repo_root nvarchar(4000) NOT NULL);

DECLARE @RepoRoot nvarchar(4000) = N''; -- <-- EDIT THIS ONE LINE if auto-detection below does not match your machine.

-- Convenience fallback for this container/repo path. Windows SSMS users should
-- paste their own absolute Windows path in @RepoRoot above.
IF NULLIF(LTRIM(RTRIM(@RepoRoot)), N'') IS NULL
BEGIN
  SET @RepoRoot = N'/workspace/lisska_2026';
END;

-- Normalize a trailing slash/backslash away so path concatenation is stable.
WHILE RIGHT(@RepoRoot, 1) IN (N'\', N'/') SET @RepoRoot = LEFT(@RepoRoot, LEN(@RepoRoot) - 1);
INSERT INTO #twfe_config(repo_root) VALUES (@RepoRoot);

IF DB_ID(N'lisska_2026_twfe') IS NULL CREATE DATABASE lisska_2026_twfe;
GO
USE lisska_2026_twfe;
GO

DROP TABLE IF EXISTS dbo.ca_county_year_panel;
DROP TABLE IF EXISTS dbo.stg_ca_counties;
DROP TABLE IF EXISTS dbo.stg_acs;
DROP TABLE IF EXISTS dbo.stg_rural;
DROP TABLE IF EXISTS dbo.stg_eia_seds;
DROP TABLE IF EXISTS dbo.stg_fuel_tax_stats;
DROP TABLE IF EXISTS dbo.stg_ev_stations;
DROP TABLE IF EXISTS dbo.stg_air_monitor;
DROP TABLE IF EXISTS dbo.stg_cec_gasoline_long;
DROP TABLE IF EXISTS dbo.clean_counties;
DROP TABLE IF EXISTS dbo.clean_acs;
DROP TABLE IF EXISTS dbo.clean_gasoline;
DROP TABLE IF EXISTS dbo.clean_air_quality;
DROP TABLE IF EXISTS dbo.clean_ev_dose;
GO

CREATE TABLE dbo.stg_ca_counties (
  STATEFP varchar(2), COUNTYFP varchar(3), COUNTYNS varchar(20), GEOID varchar(5), GEOIDFQ varchar(30), NAME nvarchar(100),
  NAMELSAD nvarchar(120), LSAD varchar(10), CLASSFP varchar(10), MTFCC varchar(10), CSAFP varchar(10), CBSAFP varchar(10),
  METDIVFP varchar(10), FUNCSTAT varchar(10), ALAND float, AWATER float, INTPTLAT float, INTPTLON float, geometry nvarchar(max)
);
CREATE TABLE dbo.stg_acs (
  county_name nvarchar(200), median_hh_income float, total_population float, pop_white_non_hispanic float,
  pop_hispanic_any_race float, pop_black_non_hispanic float, housing_units_total float, housing_units_owner_occupied float,
  commuters_total float, commuters_drove_alone float, hh_income_total float, hh_income_under_10k float,
  hh_income_10k_to_14999 float, hh_income_15k_to_19999 float, hh_income_20k_to_24999 float, hh_income_25k_to_29999 float,
  hh_income_30k_to_34999 float, hh_income_35k_to_39999 float, hh_income_40k_to_44999 float, hh_income_45k_to_49999 float,
  hh_income_50k_to_59999 float, hh_income_60k_to_74999 float, hh_income_75k_to_99999 float, hh_income_100k_to_124999 float,
  hh_income_125k_to_149999 float, hh_income_150k_to_199999 float, hh_income_200k_and_over float,
  state_fips varchar(2), county_fips varchar(3), share_under_150k float
);
CREATE TABLE dbo.stg_rural (FIPS varchar(5), State varchar(2), County_Name nvarchar(120), Attribute varchar(50), Value nvarchar(100));
CREATE TABLE dbo.stg_eia_seds (period int, stateId varchar(2), seriesId varchar(20), seriesDescription nvarchar(300), value float, unit nvarchar(100), gallons float);
CREATE TABLE dbo.stg_fuel_tax_stats ([Fiscal Year From] int, [Fiscal Year To] int, [Gasoline Taxable Distributions (Gallons)] float, [Gasoline Tax Rate Per Gallon as of July 1] float, [Gasoline Revenue] float, [Gasoline Refund] float, [Gasoline Taxpayers as of June 30] int);
CREATE TABLE dbo.stg_cec_gasoline_long (county nvarchar(100), [year] int, gasoline_million_gallons float, gasoline_gallons float);
CREATE TABLE dbo.stg_ev_stations (
  access_code nvarchar(50), access_days_time nvarchar(max), access_detail_code nvarchar(100), cards_accepted nvarchar(max), date_last_confirmed nvarchar(50),
  expected_date nvarchar(50), fuel_type_code varchar(20), groups_with_access_code nvarchar(100), id int, maximum_vehicle_class nvarchar(20), open_date nvarchar(50),
  owner_type_code nvarchar(20), related_stations nvarchar(max), restricted_access nvarchar(10), status_code nvarchar(20), funding_sources nvarchar(max),
  facility_type nvarchar(100), station_name nvarchar(300), station_phone nvarchar(100), updated_at nvarchar(100), geocode_status nvarchar(50),
  latitude float, longitude float, city nvarchar(100), country varchar(5), intersection_directions nvarchar(max), plus4 nvarchar(20), state varchar(2),
  street_address nvarchar(300), zip nvarchar(20), bd_blends nvarchar(max), cng_dispenser_num nvarchar(100), cng_fill_type_code nvarchar(50),
  cng_has_rng nvarchar(20), cng_psi nvarchar(100), cng_renewable_source nvarchar(100), cng_total_compression nvarchar(100), cng_total_storage nvarchar(100),
  cng_vehicle_class nvarchar(100), e85_blender_pump nvarchar(100), e85_other_ethanol_blends nvarchar(100), ev_connector_types nvarchar(max),
  ev_dc_fast_num float, ev_level1_evse_num float, ev_level2_evse_num float, ev_network nvarchar(100), ev_network_web nvarchar(300), ev_other_evse nvarchar(100),
  ev_pricing nvarchar(max), ev_renewable_source nvarchar(100), ev_workplace_charging nvarchar(50), hy_is_retail nvarchar(50), hy_pressures nvarchar(100),
  hy_standards nvarchar(100), hy_status_link nvarchar(300), lng_has_rng nvarchar(50), lng_renewable_source nvarchar(100), lng_vehicle_class nvarchar(100),
  lpg_nozzle_types nvarchar(100), lpg_primary nvarchar(50), ng_fill_type_code nvarchar(50), ng_psi nvarchar(100), ng_vehicle_class nvarchar(100),
  rd_blended_with_biodiesel nvarchar(100), rd_blends nvarchar(100), rd_blends_fr nvarchar(100), rd_max_biodiesel_level nvarchar(100), nps_unit_name nvarchar(200),
  access_days_time_fr nvarchar(max), intersection_directions_fr nvarchar(max), bd_blends_fr nvarchar(max), groups_with_access_code_fr nvarchar(max),
  ev_pricing_fr nvarchar(max), ev_charging_units nvarchar(max), ev_network_ids nvarchar(max), federal_agency nvarchar(200)
);
CREATE TABLE dbo.stg_air_monitor (
  [State Code] varchar(2), [County Code] varchar(3), [Site Num] varchar(10), [Parameter Code] int, POC int, Latitude float, Longitude float,
  Datum varchar(20), [Parameter Name] nvarchar(100), [Sample Duration] nvarchar(100), [Pollutant Standard] nvarchar(100), [Metric Used] nvarchar(300),
  [Method Name] nvarchar(300), [Year] int, [Units of Measure] nvarchar(100), [Event Type] nvarchar(100), [Observation Count] float,
  [Observation Percent] float, [Completeness Indicator] varchar(10), [Valid Day Count] float, [Required Day Count] float, [Exceptional Data Count] float,
  [Null Data Count] float, [Primary Exceedance Count] float, [Secondary Exceedance Count] float, [Certification Indicator] varchar(10),
  [Num Obs Below MDL] float, [Arithmetic Mean] float, [Arithmetic Standard Dev] float, [1st Max Value] float, [1st Max DateTime] nvarchar(50),
  [2nd Max Value] float, [2nd Max DateTime] nvarchar(50), [3rd Max Value] float, [3rd Max DateTime] nvarchar(50), [4th Max Value] float,
  [4th Max DateTime] nvarchar(50), [1st Max Non Overlapping Value] float, [1st NO Max DateTime] nvarchar(50), [2nd Max Non Overlapping Value] float,
  [2nd NO Max DateTime] nvarchar(50), [99th Percentile] float, [98th Percentile] float, [95th Percentile] float, [90th Percentile] float,
  [75th Percentile] float, [50th Percentile] float, [10th Percentile] float, [Local Site Name] nvarchar(200), Address nvarchar(300),
  [State Name] nvarchar(100), [County Name] nvarchar(100), [City Name] nvarchar(100), [CBSA Name] nvarchar(200), [Date of Last Change] date
);
GO

DECLARE @RepoRoot nvarchar(4000) = (SELECT repo_root FROM #twfe_config);
DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'/', @RepoRoot) > 0 AND CHARINDEX(N'\', @RepoRoot) = 0 THEN N'/' ELSE N'\' END;
DECLARE @sql nvarchar(max), @path nvarchar(4000);

SET @path = @RepoRoot + @sep + N'data' + @sep + N'county_spatial_data' + @sep + N'ca_counties.csv';
SET @sql = N'BULK INSERT dbo.stg_ca_counties FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'data' + @sep + N'sociodemographic' + @sep + N'census_acs_county_data.csv';
SET @sql = N'BULK INSERT dbo.stg_acs FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'data' + @sep + N'rurality_classification' + @sep + N'rural_classification.csv';
SET @sql = N'BULK INSERT dbo.stg_rural FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'data' + @sep + N'gasoline_consumption' + @sep + N'eia_seds_gasoline_ca.csv';
SET @sql = N'BULK INSERT dbo.stg_eia_seds FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'data' + @sep + N'gasoline_consumption' + @sep + N'fuel_tax_stats.csv';
SET @sql = N'BULK INSERT dbo.stg_fuel_tax_stats FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'data' + @sep + N'ev_charging_infrastructure' + @sep + N'ev_charging_stations_ca.csv';
SET @sql = N'BULK INSERT dbo.stg_ev_stations FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + @sep + N'ca_cec_county_gasoline_long.csv';
SET @sql = N'BULK INSERT dbo.stg_cec_gasoline_long FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);

DECLARE @y int = 2010;
WHILE @y <= 2025
BEGIN
  SET @path = @RepoRoot + @sep + N'data' + @sep + N'air_quality' + @sep + N'annual_conc_by_monitor_' + CONVERT(varchar(4), @y) + N'.csv';
  SET @sql = N'BULK INSERT dbo.stg_air_monitor FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);';
  EXEC(@sql);
  SET @y += 1;
END;
GO

SELECT GEOID AS fips, NAME AS county, UPPER(NAME) AS county_key, ALAND AS aland, INTPTLAT AS county_lat, INTPTLON AS county_lon,
       geometry::STGeomFromText([geometry], 4326).MakeValid() AS county_geom
INTO dbo.clean_counties
FROM dbo.stg_ca_counties;
GO

SELECT CONCAT(state_fips, RIGHT('000' + county_fips, 3)) AS fips, median_hh_income, total_population, share_under_150k,
       LOG(NULLIF(median_hh_income, 0)) AS log_med_hh_inc,
       LOG(NULLIF(total_population, 0)) AS log_population,
       pop_white_non_hispanic / NULLIF(total_population, 0) AS share_white_nh,
       housing_units_owner_occupied / NULLIF(housing_units_total, 0) AS share_owner_occupied,
       commuters_drove_alone / NULLIF(commuters_total, 0) AS share_commute_alone
INTO dbo.clean_acs
FROM dbo.stg_acs
WHERE state_fips = '06';
GO

SELECT UPPER(county) AS county_key, [year], gasoline_gallons
INTO dbo.clean_gasoline
FROM dbo.stg_cec_gasoline_long
WHERE UPPER(county) <> 'TOTAL';
GO

SELECT CONCAT([State Code], RIGHT('000' + [County Code], 3)) AS fips, [Year] AS [year],
       AVG(CASE WHEN [Parameter Code] = 88101 AND [Sample Duration] LIKE '%24%' THEN [Arithmetic Mean] END) AS pm25,
       AVG(CASE WHEN [Parameter Code] = 44201 AND [Sample Duration] LIKE '%8-HR%' THEN [4th Max Value] END) AS o3
INTO dbo.clean_air_quality
FROM dbo.stg_air_monitor
WHERE [State Code] = '06'
GROUP BY CONCAT([State Code], RIGHT('000' + [County Code], 3)), [Year];
GO

WITH ev_geo AS (
  SELECT e.*, geometry::Point(longitude, latitude, 4326) AS station_geom
  FROM dbo.stg_ev_stations e
  WHERE state = 'CA' AND latitude IS NOT NULL AND longitude IS NOT NULL AND TRY_CONVERT(date, open_date) <= '2021-12-31'
), joined AS (
  SELECT c.fips, e.ev_dc_fast_num, e.ev_level2_evse_num
  FROM ev_geo e
  INNER JOIN dbo.clean_counties c ON c.county_geom.STContains(e.station_geom) = 1
), agg AS (
  SELECT fips, SUM(COALESCE(ev_dc_fast_num,0)) AS dcfc_ports_2021, SUM(COALESCE(ev_level2_evse_num,0)) AS l2_ports_2021
  FROM joined GROUP BY fips
), base AS (
  SELECT c.fips, COALESCE(a.dcfc_ports_2021,0) AS dcfc_ports_2021, COALESCE(a.l2_ports_2021,0) AS l2_ports_2021,
         COALESCE(a.dcfc_ports_2021,0) / NULLIF(acs.total_population / 10000.0, 0) AS dcfc_density_2021
  FROM dbo.clean_counties c
  LEFT JOIN agg a ON c.fips = a.fips
  LEFT JOIN dbo.clean_acs acs ON c.fips = acs.fips
), winsor AS (
  SELECT PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY dcfc_density_2021) OVER () AS p01,
         PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY dcfc_density_2021) OVER () AS p99,
         *
  FROM base
)
SELECT fips, dcfc_ports_2021, l2_ports_2021, dcfc_density_2021,
       CASE WHEN dcfc_density_2021 < p01 THEN p01 WHEN dcfc_density_2021 > p99 THEN p99 ELSE dcfc_density_2021 END AS dose_dcfc_density,
       POWER(CASE WHEN dcfc_density_2021 < p01 THEN p01 WHEN dcfc_density_2021 > p99 THEN p99 ELSE dcfc_density_2021 END, 2) AS dose_dcfc_density_sq,
       LOG((CASE WHEN dcfc_density_2021 < p01 THEN p01 WHEN dcfc_density_2021 > p99 THEN p99 ELSE dcfc_density_2021 END) + SQRT(POWER((CASE WHEN dcfc_density_2021 < p01 THEN p01 WHEN dcfc_density_2021 > p99 THEN p99 ELSE dcfc_density_2021 END), 2) + 1)) AS ihs_dose_dcfc_density,
       dcfc_ports_2021 / NULLIF(dcfc_ports_2021 + l2_ports_2021, 0) AS share_dcfc_2021
INTO dbo.clean_ev_dose
FROM winsor;
GO

WITH years AS (
  SELECT 2010 AS [year] UNION ALL SELECT [year] + 1 FROM years WHERE [year] < 2025
), skeleton AS (
  SELECT c.fips, c.county, c.county_key, c.aland, y.[year] FROM dbo.clean_counties c CROSS JOIN years y
), rural AS (
  SELECT FIPS AS fips, TRY_CONVERT(int, Value) AS rucc_2023 FROM dbo.stg_rural WHERE State = 'CA' AND Attribute = 'RUCC_2023'
)
SELECT s.fips, s.county, s.aland, s.[year],
       g.gasoline_gallons, g.gasoline_gallons / NULLIF(a.total_population, 0) AS gasoline_pc,
       LOG(1 + g.gasoline_gallons / NULLIF(a.total_population, 0)) AS log_gasoline_pc,
       q.pm25, LOG(1 + q.pm25) AS log_pm25, q.o3, LOG(1 + q.o3) AS log_o3,
       d.dcfc_ports_2021, d.l2_ports_2021, d.dose_dcfc_density, d.dose_dcfc_density_sq, d.ihs_dose_dcfc_density, d.share_dcfc_2021,
       CASE WHEN s.[year] >= 2022 THEN 1 ELSE 0 END AS post_nevi,
       CASE WHEN s.[year] >= 2026 THEN 1 ELSE 0 END AS post_obbba,
       d.dose_dcfc_density * CASE WHEN s.[year] >= 2022 THEN 1 ELSE 0 END AS dose_x_post_nevi,
       d.dose_dcfc_density_sq * CASE WHEN s.[year] >= 2022 THEN 1 ELSE 0 END AS dose_sq_x_post_nevi,
       d.dose_dcfc_density * CASE WHEN s.[year] >= 2026 THEN 1 ELSE 0 END AS dose_x_post_obbba,
       a.median_hh_income, a.total_population, a.share_under_150k, a.log_med_hh_inc, a.log_population, a.share_white_nh,
       a.share_owner_occupied, a.share_commute_alone, rural.rucc_2023,
       e.value AS gasoline_price_dollars_per_mmbtu, e.gallons AS eia_gasoline_gallons
INTO dbo.ca_county_year_panel
FROM skeleton s
LEFT JOIN dbo.clean_acs a ON s.fips = a.fips
LEFT JOIN rural ON s.fips = rural.fips
LEFT JOIN dbo.clean_gasoline g ON s.county_key = g.county_key AND s.[year] = g.[year]
LEFT JOIN dbo.clean_air_quality q ON s.fips = q.fips AND s.[year] = q.[year]
LEFT JOIN dbo.clean_ev_dose d ON s.fips = d.fips
LEFT JOIN dbo.stg_eia_seds e ON s.[year] = e.period
OPTION (MAXRECURSION 100);
GO

SELECT COUNT(*) AS panel_rows, COUNT(DISTINCT fips) AS counties, MIN([year]) AS first_year, MAX([year]) AS last_year
FROM dbo.ca_county_year_panel;
