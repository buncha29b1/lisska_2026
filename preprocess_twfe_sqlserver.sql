/*
SQL Server preprocessing for the continuous-treatment TWFE panel.

Run in SQL Server Management Studio with SQLCMD Mode enabled. Keep this file in
the repository root. Set RepoRoot to the absolute path of this repo if SSMS is
not launched from the repo directory.

:setvar RepoRoot "C:\absolute\path\to\lisska_2026"
*/

SET NOCOUNT ON;
DECLARE @RepoRoot nvarchar(4000) = N'$(RepoRoot)';
IF @RepoRoot LIKE N'$' + N'(RepoRoot)' SET @RepoRoot = CONVERT(nvarchar(4000), SERVERPROPERTY('MachineName'));

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
DROP TABLE IF EXISTS dbo.stg_cec_gasoline_wide;
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
CREATE TABLE dbo.stg_ev_stations (
  access_code nvarchar(50), access_days_time nvarchar(max), access_detail_code nvarchar(100), cards_accepted nvarchar(max), date_last_confirmed date,
  expected_date date, fuel_type_code varchar(20), groups_with_access_code nvarchar(100), id int, maximum_vehicle_class nvarchar(20), open_date date,
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

DECLARE @RepoRoot nvarchar(4000) = N'$(RepoRoot)';
IF @RepoRoot LIKE N'$' + N'(RepoRoot)' THROW 50001, 'Enable SQLCMD Mode and set :setvar RepoRoot to the absolute repo path.', 1;
DECLARE @sql nvarchar(max), @path nvarchar(4000);

SET @path = @RepoRoot + N'\data\county_spatial_data\ca_counties.csv';
SET @sql = N'BULK INSERT dbo.stg_ca_counties FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + N'\data\sociodemographic\census_acs_county_data.csv';
SET @sql = N'BULK INSERT dbo.stg_acs FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + N'\data\rurality_classification\rural_classification.csv';
SET @sql = N'BULK INSERT dbo.stg_rural FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + N'\data\gasoline_consumption\eia_seds_gasoline_ca.csv';
SET @sql = N'BULK INSERT dbo.stg_eia_seds FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + N'\data\gasoline_consumption\fuel_tax_stats.csv';
SET @sql = N'BULK INSERT dbo.stg_fuel_tax_stats FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);
SET @path = @RepoRoot + N'\data\ev_charging_infrastructure\ev_charging_stations_ca.csv';
SET @sql = N'BULK INSERT dbo.stg_ev_stations FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);'; EXEC(@sql);

DECLARE @y int = 2010;
WHILE @y <= 2025
BEGIN
  SET @path = @RepoRoot + N'\data\air_quality\annual_conc_by_monitor_' + CONVERT(varchar(4), @y) + N'.csv';
  SET @sql = N'BULK INSERT dbo.stg_air_monitor FROM ''' + @path + N''' WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDQUOTE=''"'', TABLOCK);';
  EXEC(@sql);
  SET @y += 1;
END;
GO

-- The CEC workbook is loaded with OPENROWSET. Install/enable Microsoft.ACE.OLEDB.12.0 first if your SQL Server does not have it.
DECLARE @RepoRoot2 nvarchar(4000) = N'$(RepoRoot)';
DECLARE @xlsx nvarchar(4000) = @RepoRoot2 + N'\data\gasoline_consumption\cec_a15_county_gasoline.xlsx';
DECLARE @sql2 nvarchar(max) = N'
SELECT * INTO dbo.stg_cec_gasoline_wide
FROM OPENROWSET(''Microsoft.ACE.OLEDB.12.0'', ''Excel 12.0;HDR=NO;IMEX=1;Database=' + @xlsx + N''', ''SELECT * FROM [Retail Gasoline Sales by County$]'');';
EXEC(@sql2);
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

-- Convert the CEC two-row header workbook layout to long county-year gasoline gallons.
-- If OPENROWSET produces different F-column names on your machine, inspect dbo.stg_cec_gasoline_wide and adjust this VALUES map.
WITH src AS (
  SELECT * FROM dbo.stg_cec_gasoline_wide WHERE F1 IS NOT NULL AND F1 NOT IN ('County', 'Retail Gasoline Sales by County', '(Millions of Gallons)')
), long_gas AS (
  SELECT UPPER(CAST(F1 AS nvarchar(100))) AS county_key, v.[year], TRY_CONVERT(float, v.million_gallons) * 1000000.0 AS gasoline_gallons
  FROM src
  CROSS APPLY (VALUES
    (2010,F3),(2011,F5),(2012,F7),(2013,F9),(2014,F11),(2015,F13),(2016,F15),(2017,F17),(2018,F19),(2019,F21),
    (2020,F23),(2021,F25),(2022,F27),(2023,F29),(2024,F31)
  ) v([year], million_gallons)
)
SELECT county_key, [year], gasoline_gallons INTO dbo.clean_gasoline FROM long_gas;
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
  WHERE state = 'CA' AND latitude IS NOT NULL AND longitude IS NOT NULL AND open_date <= '2021-12-31'
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
