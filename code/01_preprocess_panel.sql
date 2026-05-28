/* =====================================================================
   01_preprocess_panel.sql
   ---------------------------------------------------------------------
   T-SQL preprocessing pipeline for the California EV-charging /
   gasoline-displacement project.

       RDBMS  : Microsoft SQL Server 2019+ (SSMS, regular Execute mode)
       Output : EVPanel.analytic.panel_county_year
                (58 California counties x 16 years, 2010-2025 = 928 rows)

   To run:
       1. Verify @data_root below matches the path to the data folder.
       2. Open this file in SSMS and press F5 / Execute.
          NO SQLCMD mode required.

   How problematic CSVs are handled:
     - ca_counties.csv      : the WKT `geometry` column has 1000s of
                              embedded commas that BULK INSERT cannot
                              parse. We use PowerShell (via xp_cmdshell)
                              to emit a slim CSV with only the metadata
                              columns we need, then BULK INSERT that.
     - rural_classification : long Description strings have unquoted
                              commas. We filter those rows out with
                              PowerShell, re-encode to UTF-8, then load.
     - annual_conc_by_monitor*.csv  : ~9k rows/yr with messy quoting.
                              PowerShell filters to CA + PM2.5 + Ozone
                              before BULK INSERT.
     - ev_charging_stations : ~19k rows with INT columns that hold ''.
                              We load every column as NVARCHAR(MAX)
                              into the raw table, then TRY_CONVERT in
                              the staging step.
     - everything else      : direct BULK INSERT works.

   EV-station -> county join is performed by nearest-centroid Haversine
   distance (avoids the SQL Server GEOGRAPHY polygon dependency on the
   WKT column). The Python script uses the same rule so the two panels
   agree row-for-row.
   ===================================================================== */

SET NOCOUNT ON;
SET ANSI_NULLS ON;
SET QUOTED_IDENTIFIER ON;
GO

------------------------------------------------------------------
-- 0. Database + configuration
------------------------------------------------------------------
USE master;
IF DB_ID('EVPanel') IS NULL EXEC('CREATE DATABASE EVPanel;');
GO
USE EVPanel;
GO

-- >>> EDIT HERE IF THE DATA FOLDER MOVES <<<
IF OBJECT_ID('dbo.cfg','U') IS NOT NULL DROP TABLE dbo.cfg;
CREATE TABLE dbo.cfg (k NVARCHAR(64) PRIMARY KEY, v NVARCHAR(400));
INSERT INTO dbo.cfg VALUES
    (N'data_root',  N'C:\Users\Trong Khoi Van\Desktop\Denison\Summer Research 2026\data'),
    (N'clean_root', N'C:\Users\Trong Khoi Van\Desktop\Denison\Summer Research 2026\data\_clean');
GO

------------------------------------------------------------------
-- 0.1 Enable xp_cmdshell (needed for the PowerShell pre-clean step)
------------------------------------------------------------------
EXEC sp_configure 'show advanced options', 1; RECONFIGURE;
EXEC sp_configure 'xp_cmdshell',           1; RECONFIGURE;
GO

------------------------------------------------------------------
-- 0.2 PowerShell pre-clean: emit slimmer / safer CSVs into _clean\
------------------------------------------------------------------
DECLARE @data  NVARCHAR(400) = (SELECT v FROM dbo.cfg WHERE k=N'data_root');
DECLARE @clean NVARCHAR(400) = (SELECT v FROM dbo.cfg WHERE k=N'clean_root');
DECLARE @cmd   NVARCHAR(MAX);

-- Make clean directory
SET @cmd = N'powershell -NoProfile -Command "if (-not (Test-Path -LiteralPath ''' + @clean + N''')) { New-Item -ItemType Directory -Force -Path ''' + @clean + N''' | Out-Null }"';
EXEC xp_cmdshell @cmd, no_output;

-- ca_counties.csv -> drop the geometry column (the WKT column with embedded commas)
SET @cmd = N'powershell -NoProfile -Command "Import-Csv -LiteralPath ''' + @data + N'\county_spatial_data\ca_counties.csv'' | Select-Object STATEFP,COUNTYFP,GEOID,NAME,ALAND,AWATER,INTPTLAT,INTPTLON | Export-Csv -LiteralPath ''' + @clean + N'\ca_counties.csv'' -NoTypeInformation -Encoding UTF8"';
EXEC xp_cmdshell @cmd, no_output;

-- rural_classification.csv -> filter out Description rows, re-encode UTF8
SET @cmd = N'powershell -NoProfile -Command "Import-Csv -LiteralPath ''' + @data + N'\rurality_classification\rural_classification.csv'' -Encoding Default | Where-Object { $_.Attribute -ne ''Description'' } | Export-Csv -LiteralPath ''' + @clean + N'\rural_classification.csv'' -NoTypeInformation -Encoding UTF8"';
EXEC xp_cmdshell @cmd, no_output;

-- annual_conc_by_monitor_YYYY.csv -> for each year, keep only CA (State Code='06') rows for PM2.5 (88101) and Ozone (44201). This is a 30-90x size reduction.
DECLARE @y INT = 2010;
WHILE @y <= 2025
BEGIN
    DECLARE @ysrc NVARCHAR(500) = @data  + N'\air_quality\annual_conc_by_monitor_' + CAST(@y AS NVARCHAR(4)) + N'.csv';
    DECLARE @ydst NVARCHAR(500) = @clean + N'\annual_conc_by_monitor_'           + CAST(@y AS NVARCHAR(4)) + N'.csv';
    SET @cmd = N'powershell -NoProfile -Command "if (Test-Path -LiteralPath ''' + @ysrc + N''') { Import-Csv -LiteralPath ''' + @ysrc + N''' | Where-Object { $_.''State Code'' -eq ''06'' -and ($_.''Parameter Code'' -eq ''88101'' -or $_.''Parameter Code'' -eq ''44201'') } | Export-Csv -LiteralPath ''' + @ydst + N''' -NoTypeInformation -Encoding UTF8 }"';
    EXEC xp_cmdshell @cmd, no_output;
    SET @y = @y + 1;
END;
GO

------------------------------------------------------------------
-- 1. Schemas
------------------------------------------------------------------
IF SCHEMA_ID('raw')      IS NULL EXEC('CREATE SCHEMA raw      AUTHORIZATION dbo;');
IF SCHEMA_ID('stg')      IS NULL EXEC('CREATE SCHEMA stg      AUTHORIZATION dbo;');
IF SCHEMA_ID('dim')      IS NULL EXEC('CREATE SCHEMA dim      AUTHORIZATION dbo;');
IF SCHEMA_ID('fact')     IS NULL EXEC('CREATE SCHEMA fact     AUTHORIZATION dbo;');
IF SCHEMA_ID('analytic') IS NULL EXEC('CREATE SCHEMA analytic AUTHORIZATION dbo;');
GO

------------------------------------------------------------------
-- 2. Year dimension (Post_NEVI, Post_OBBBA, partial-2025 weight)
------------------------------------------------------------------
IF OBJECT_ID('dim.year','U') IS NOT NULL DROP TABLE dim.year;
CREATE TABLE dim.year (
    year_id      SMALLINT     NOT NULL PRIMARY KEY,
    post_nevi    BIT          NOT NULL,
    post_obbba   BIT          NOT NULL,
    obbba_weight DECIMAL(6,4) NOT NULL
);
INSERT INTO dim.year (year_id, post_nevi, post_obbba, obbba_weight)
SELECT y,
       CASE WHEN y >= 2022 THEN 1 ELSE 0 END,
       CASE WHEN y >= 2026 THEN 1 ELSE 0 END,
       CASE WHEN y = 2025  THEN CAST(92.0/365.0 AS DECIMAL(6,4))
            WHEN y >= 2026 THEN 1.0
            ELSE 0.0 END
FROM (VALUES (2010),(2011),(2012),(2013),(2014),(2015),(2016),(2017),
             (2018),(2019),(2020),(2021),(2022),(2023),(2024),(2025))
     AS v(y);
GO

------------------------------------------------------------------
-- 3. Dynamic BULK INSERT helper (used everywhere a path is needed)
------------------------------------------------------------------
IF OBJECT_ID('dbo.usp_bulk_load','P') IS NOT NULL DROP PROCEDURE dbo.usp_bulk_load;
GO
CREATE PROCEDURE dbo.usp_bulk_load
    @target NVARCHAR(200),
    @fullpath NVARCHAR(500)
AS
BEGIN
    DECLARE @sql NVARCHAR(MAX) =
        N'BULK INSERT ' + @target +
        N' FROM ''' + @fullpath + N''' ' +
        N'WITH (FORMAT=''CSV'', FIRSTROW=2, FIELDTERMINATOR='','', ' +
        N'      ROWTERMINATOR=''0x0a'', FIELDQUOTE=''"'', CODEPAGE=''65001'', ' +
        N'      MAXERRORS=999999, KEEPNULLS, TABLOCK);';
    EXEC sp_executesql @sql;
END;
GO

------------------------------------------------------------------
-- 4. dim.county (loaded from the cleaned ca_counties.csv)
--     Clean file columns: STATEFP, COUNTYFP, GEOID, NAME, ALAND,
--                         AWATER, INTPTLAT, INTPTLON
------------------------------------------------------------------
IF OBJECT_ID('raw.ca_counties','U') IS NOT NULL DROP TABLE raw.ca_counties;
CREATE TABLE raw.ca_counties (
    STATEFP   NVARCHAR(8),
    COUNTYFP  NVARCHAR(8),
    GEOID     NVARCHAR(16),
    NAME      NVARCHAR(64),
    ALAND     NVARCHAR(32),
    AWATER    NVARCHAR(32),
    INTPTLAT  NVARCHAR(32),
    INTPTLON  NVARCHAR(32)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'clean_root') + N'\ca_counties.csv';
EXEC dbo.usp_bulk_load N'raw.ca_counties', @p;
GO

IF OBJECT_ID('dim.county','U') IS NOT NULL DROP TABLE dim.county;
CREATE TABLE dim.county (
    fips         CHAR(5)      NOT NULL PRIMARY KEY,
    county_name  NVARCHAR(64) NOT NULL,
    centroid_lat FLOAT        NOT NULL,
    centroid_lon FLOAT        NOT NULL,
    aland_m2     BIGINT       NULL,
    awater_m2    BIGINT       NULL
);
INSERT INTO dim.county (fips, county_name, centroid_lat, centroid_lon, aland_m2, awater_m2)
SELECT
    RIGHT('00000' + CAST(TRY_CAST(STATEFP AS INT)*1000
                       + TRY_CAST(COUNTYFP AS INT) AS VARCHAR(5)), 5)  AS fips,
    NAME,
    TRY_CAST(INTPTLAT AS FLOAT),
    TRY_CAST(INTPTLON AS FLOAT),
    TRY_CAST(ALAND    AS BIGINT),
    TRY_CAST(AWATER   AS BIGINT)
FROM raw.ca_counties
WHERE TRY_CAST(STATEFP AS INT) = 6
  AND TRY_CAST(INTPTLAT AS FLOAT) IS NOT NULL
  AND TRY_CAST(INTPTLON AS FLOAT) IS NOT NULL;
GO

------------------------------------------------------------------
-- 5. raw.ev_stations -- all columns NVARCHAR(MAX) to tolerate any
--    quoting/typing peculiarities. We never use the columns we
--    don't care about; type conversion happens in stg.
------------------------------------------------------------------
IF OBJECT_ID('raw.ev_stations','U') IS NOT NULL DROP TABLE raw.ev_stations;
CREATE TABLE raw.ev_stations (
    access_code NVARCHAR(MAX),  access_days_time NVARCHAR(MAX),
    access_detail_code NVARCHAR(MAX), cards_accepted NVARCHAR(MAX),
    date_last_confirmed NVARCHAR(MAX), expected_date NVARCHAR(MAX),
    fuel_type_code NVARCHAR(MAX), groups_with_access_code NVARCHAR(MAX),
    id NVARCHAR(MAX), maximum_vehicle_class NVARCHAR(MAX),
    open_date NVARCHAR(MAX), owner_type_code NVARCHAR(MAX),
    related_stations NVARCHAR(MAX), restricted_access NVARCHAR(MAX),
    status_code NVARCHAR(MAX), funding_sources NVARCHAR(MAX),
    facility_type NVARCHAR(MAX), station_name NVARCHAR(MAX),
    station_phone NVARCHAR(MAX), updated_at NVARCHAR(MAX),
    geocode_status NVARCHAR(MAX),
    latitude NVARCHAR(MAX), longitude NVARCHAR(MAX),
    city NVARCHAR(MAX), country NVARCHAR(MAX),
    intersection_directions NVARCHAR(MAX), plus4 NVARCHAR(MAX),
    state NVARCHAR(MAX), street_address NVARCHAR(MAX), zip NVARCHAR(MAX),
    bd_blends NVARCHAR(MAX), cng_dispenser_num NVARCHAR(MAX),
    cng_fill_type_code NVARCHAR(MAX), cng_has_rng NVARCHAR(MAX),
    cng_psi NVARCHAR(MAX), cng_renewable_source NVARCHAR(MAX),
    cng_total_compression NVARCHAR(MAX), cng_total_storage NVARCHAR(MAX),
    cng_vehicle_class NVARCHAR(MAX), e85_blender_pump NVARCHAR(MAX),
    e85_other_ethanol_blends NVARCHAR(MAX),
    ev_connector_types NVARCHAR(MAX),
    ev_dc_fast_num NVARCHAR(MAX), ev_level1_evse_num NVARCHAR(MAX),
    ev_level2_evse_num NVARCHAR(MAX),
    ev_network NVARCHAR(MAX), ev_network_web NVARCHAR(MAX),
    ev_other_evse NVARCHAR(MAX), ev_pricing NVARCHAR(MAX),
    ev_renewable_source NVARCHAR(MAX), ev_workplace_charging NVARCHAR(MAX),
    hy_is_retail NVARCHAR(MAX), hy_pressures NVARCHAR(MAX),
    hy_standards NVARCHAR(MAX), hy_status_link NVARCHAR(MAX),
    lng_has_rng NVARCHAR(MAX), lng_renewable_source NVARCHAR(MAX),
    lng_vehicle_class NVARCHAR(MAX), lpg_nozzle_types NVARCHAR(MAX),
    lpg_primary NVARCHAR(MAX), ng_fill_type_code NVARCHAR(MAX),
    ng_psi NVARCHAR(MAX), ng_vehicle_class NVARCHAR(MAX),
    rd_blended_with_biodiesel NVARCHAR(MAX), rd_blends NVARCHAR(MAX),
    rd_blends_fr NVARCHAR(MAX), rd_max_biodiesel_level NVARCHAR(MAX),
    nps_unit_name NVARCHAR(MAX), access_days_time_fr NVARCHAR(MAX),
    intersection_directions_fr NVARCHAR(MAX), bd_blends_fr NVARCHAR(MAX),
    groups_with_access_code_fr NVARCHAR(MAX), ev_pricing_fr NVARCHAR(MAX),
    ev_charging_units NVARCHAR(MAX), ev_network_ids NVARCHAR(MAX),
    federal_agency NVARCHAR(MAX)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'data_root')
                          + N'\ev_charging_infrastructure\ev_charging_stations_ca.csv';
EXEC dbo.usp_bulk_load N'raw.ev_stations', @p;
GO

-- Typed staging + nearest-centroid spatial join to dim.county
IF OBJECT_ID('stg.ev_stations','U') IS NOT NULL DROP TABLE stg.ev_stations;
CREATE TABLE stg.ev_stations (
    station_id   BIGINT       NULL,
    open_date    DATE         NULL,
    status_code  NVARCHAR(8)  NULL,
    state        NVARCHAR(8)  NULL,
    zip          CHAR(5)      NULL,
    city         NVARCHAR(64) NULL,
    latitude     FLOAT        NULL,
    longitude    FLOAT        NULL,
    dcfc_n       INT          NULL,
    l2_n         INT          NULL,
    l1_n         INT          NULL,
    ev_network   NVARCHAR(64) NULL,
    fips         CHAR(5)      NULL
);

INSERT INTO stg.ev_stations (station_id, open_date, status_code, state, zip,
                             city, latitude, longitude, dcfc_n, l2_n, l1_n,
                             ev_network, fips)
SELECT
    TRY_CAST(s.id AS BIGINT)                          AS station_id,
    TRY_CONVERT(DATE, s.open_date, 23)                AS open_date,
    s.status_code,
    s.state,
    LEFT(REPLACE(ISNULL(s.zip,''),'-',''),5)          AS zip,
    s.city,
    TRY_CAST(s.latitude  AS FLOAT)                    AS latitude,
    TRY_CAST(s.longitude AS FLOAT)                    AS longitude,
    ISNULL(TRY_CAST(s.ev_dc_fast_num     AS INT), 0)  AS dcfc_n,
    ISNULL(TRY_CAST(s.ev_level2_evse_num AS INT), 0)  AS l2_n,
    ISNULL(TRY_CAST(s.ev_level1_evse_num AS INT), 0)  AS l1_n,
    s.ev_network,
    NULL                                              AS fips
FROM raw.ev_stations AS s
WHERE s.fuel_type_code = 'ELEC'
  AND s.state          = 'CA'
  AND s.status_code    = 'E'
  AND TRY_CONVERT(DATE, s.open_date, 23) IS NOT NULL
  AND TRY_CAST(s.latitude  AS FLOAT) BETWEEN 32.0 AND 42.5
  AND TRY_CAST(s.longitude AS FLOAT) BETWEEN -125.0 AND -113.0
  AND ( ISNULL(TRY_CAST(s.ev_dc_fast_num     AS INT), 0)
      + ISNULL(TRY_CAST(s.ev_level2_evse_num AS INT), 0)
      + ISNULL(TRY_CAST(s.ev_level1_evse_num AS INT), 0)) > 0;

-- Nearest-centroid Haversine (same rule as 02_twfe_python.py)
;WITH dists AS (
    SELECT  st.station_id, c.fips,
            2.0 * 6371.0 * ASIN(
                SQRT(
                    POWER(SIN(RADIANS((c.centroid_lat - st.latitude)/2.0)), 2)
                  + COS(RADIANS(st.latitude))
                  * COS(RADIANS(c.centroid_lat))
                  * POWER(SIN(RADIANS((c.centroid_lon - st.longitude)/2.0)), 2)
                )
            ) AS km
    FROM    stg.ev_stations AS st
    CROSS JOIN dim.county    AS c
),
ranked AS (
    SELECT  station_id, fips,
            ROW_NUMBER() OVER (PARTITION BY station_id ORDER BY km ASC) AS rn
    FROM    dists
)
UPDATE st
SET    st.fips = r.fips
FROM   stg.ev_stations AS st
JOIN   ranked          AS r ON r.station_id = st.station_id AND r.rn = 1;

DELETE FROM stg.ev_stations WHERE fips IS NULL;
GO

------------------------------------------------------------------
-- 6. ZIP -> county majority rule (built from EV-station ZIPs)
------------------------------------------------------------------
IF OBJECT_ID('dim.zip_to_county','U') IS NOT NULL DROP TABLE dim.zip_to_county;
CREATE TABLE dim.zip_to_county (
    zip        CHAR(5) NOT NULL,
    fips       CHAR(5) NOT NULL,
    n_points   INT     NOT NULL,
    is_primary BIT     NOT NULL,
    CONSTRAINT PK_zip_county PRIMARY KEY (zip, fips)
);
;WITH zc AS (
    SELECT zip, fips, COUNT(*) AS n_points
    FROM   stg.ev_stations
    WHERE  zip IS NOT NULL AND LEN(zip) = 5
    GROUP  BY zip, fips
),
r AS (
    SELECT zip, fips, n_points,
           ROW_NUMBER() OVER (PARTITION BY zip ORDER BY n_points DESC) AS rn
    FROM   zc
)
INSERT INTO dim.zip_to_county (zip, fips, n_points, is_primary)
SELECT zip, fips, n_points, CASE WHEN rn = 1 THEN 1 ELSE 0 END
FROM   r;
GO

------------------------------------------------------------------
-- 7. AQI county-year (annual_aqi_by_county_<year>.csv)
------------------------------------------------------------------
IF OBJECT_ID('raw.aqi_county','U') IS NOT NULL DROP TABLE raw.aqi_county;
CREATE TABLE raw.aqi_county (
    State NVARCHAR(64), County NVARCHAR(96), [Year] SMALLINT,
    days_aqi NVARCHAR(32), good_days NVARCHAR(32), moderate_days NVARCHAR(32),
    usg_days NVARCHAR(32), unhealthy_days NVARCHAR(32),
    very_unhealthy_days NVARCHAR(32), hazardous_days NVARCHAR(32),
    max_aqi NVARCHAR(32), p90_aqi NVARCHAR(32), median_aqi NVARCHAR(32),
    days_co NVARCHAR(32), days_no2 NVARCHAR(32), days_ozone NVARCHAR(32),
    days_pm25 NVARCHAR(32), days_pm10 NVARCHAR(32)
);
GO

DECLARE @data NVARCHAR(400) = (SELECT v FROM dbo.cfg WHERE k=N'data_root');
DECLARE @y INT = 2010, @path NVARCHAR(500);
WHILE @y <= 2025
BEGIN
    SET @path = @data + N'\air_quality\annual_aqi_by_county_'
              + CAST(@y AS NVARCHAR(4)) + N'.csv';
    EXEC dbo.usp_bulk_load N'raw.aqi_county', @path;
    SET @y = @y + 1;
END;
GO

IF OBJECT_ID('stg.aqi_county','U') IS NOT NULL DROP TABLE stg.aqi_county;
CREATE TABLE stg.aqi_county (
    fips        CHAR(5)  NOT NULL,
    year_id     SMALLINT NOT NULL,
    median_aqi  FLOAT    NULL,
    p90_aqi     FLOAT    NULL,
    max_aqi     FLOAT    NULL,
    days_pm25   FLOAT    NULL,
    days_ozone  FLOAT    NULL,
    CONSTRAINT PK_stg_aqi PRIMARY KEY (fips, year_id)
);
INSERT INTO stg.aqi_county (fips, year_id, median_aqi, p90_aqi, max_aqi,
                            days_pm25, days_ozone)
SELECT  c.fips, a.[Year],
        AVG(TRY_CAST(a.median_aqi AS FLOAT)),
        AVG(TRY_CAST(a.p90_aqi    AS FLOAT)),
        AVG(TRY_CAST(a.max_aqi    AS FLOAT)),
        AVG(TRY_CAST(a.days_pm25  AS FLOAT)),
        AVG(TRY_CAST(a.days_ozone AS FLOAT))
FROM   raw.aqi_county AS a
JOIN   dim.county     AS c ON c.county_name = a.County
WHERE  a.State = 'California' AND a.[Year] IS NOT NULL
GROUP BY c.fips, a.[Year];
GO

------------------------------------------------------------------
-- 8. AQS monitor concentrations -> PM2.5 + O3 per county-year
--     Loaded from the PowerShell-cleaned _clean\annual_conc_by_monitor_*.csv
--     (state-code filtered, parameter-code filtered, 50x smaller)
------------------------------------------------------------------
IF OBJECT_ID('raw.aqs_monitor','U') IS NOT NULL DROP TABLE raw.aqs_monitor;
CREATE TABLE raw.aqs_monitor (
    state_code     NVARCHAR(8),
    county_code    NVARCHAR(8),
    site_num       NVARCHAR(16),
    parameter_code NVARCHAR(8),
    poc            NVARCHAR(8),
    latitude       NVARCHAR(32), longitude NVARCHAR(32),
    datum          NVARCHAR(16), parameter_name NVARCHAR(96),
    sample_duration NVARCHAR(64), pollutant_standard NVARCHAR(96),
    metric_used     NVARCHAR(128), method_name NVARCHAR(256),
    [year]          NVARCHAR(8),
    units_of_measure NVARCHAR(64),
    event_type      NVARCHAR(32),
    observation_count NVARCHAR(16), observation_percent NVARCHAR(16),
    completeness_indicator NVARCHAR(8),
    valid_day_count NVARCHAR(16), required_day_count NVARCHAR(16),
    exceptional_data_count NVARCHAR(16), null_data_count NVARCHAR(16),
    primary_exceedance_count NVARCHAR(16), secondary_exceedance_count NVARCHAR(16),
    certification_indicator NVARCHAR(32),
    num_obs_below_mdl NVARCHAR(16),
    arithmetic_mean NVARCHAR(32), arithmetic_standard_dev NVARCHAR(32),
    first_max_value NVARCHAR(32), first_max_datetime NVARCHAR(32),
    second_max_value NVARCHAR(32), second_max_datetime NVARCHAR(32),
    third_max_value NVARCHAR(32), third_max_datetime NVARCHAR(32),
    fourth_max_value NVARCHAR(32), fourth_max_datetime NVARCHAR(32),
    first_max_non_overlapping_value NVARCHAR(32),
    first_no_max_datetime NVARCHAR(32),
    second_max_non_overlapping_value NVARCHAR(32),
    second_no_max_datetime NVARCHAR(32),
    ninety_ninth_percentile NVARCHAR(32),
    ninety_eighth_percentile NVARCHAR(32),
    ninety_fifth_percentile NVARCHAR(32),
    ninetieth_percentile   NVARCHAR(32),
    seventy_fifth_percentile NVARCHAR(32),
    fiftieth_percentile      NVARCHAR(32),
    tenth_percentile         NVARCHAR(32),
    local_site_name NVARCHAR(256),
    address NVARCHAR(256), state_name NVARCHAR(64),
    county_name NVARCHAR(96), city_name NVARCHAR(96),
    cbsa_name NVARCHAR(192), date_of_last_change NVARCHAR(32)
);
GO

DECLARE @clean NVARCHAR(400) = (SELECT v FROM dbo.cfg WHERE k=N'clean_root');
DECLARE @y INT = 2010, @path NVARCHAR(500);
WHILE @y <= 2025
BEGIN
    SET @path = @clean + N'\annual_conc_by_monitor_' + CAST(@y AS NVARCHAR(4)) + N'.csv';
    EXEC dbo.usp_bulk_load N'raw.aqs_monitor', @path;
    SET @y = @y + 1;
END;
GO

-- PM2.5 county-year (param=88101, 24-hr sample)
IF OBJECT_ID('stg.pm25_county','U') IS NOT NULL DROP TABLE stg.pm25_county;
CREATE TABLE stg.pm25_county (
    fips    CHAR(5)  NOT NULL,
    year_id SMALLINT NOT NULL,
    pm25_annual_ugm3 FLOAT NULL,
    pm25_98p_ugm3    FLOAT NULL,
    n_pm_monitors    INT   NULL,
    CONSTRAINT PK_stg_pm25 PRIMARY KEY (fips, year_id)
);
INSERT INTO stg.pm25_county
SELECT
    RIGHT('00000'
        + CAST(TRY_CAST(m.state_code AS INT)*1000
             + TRY_CAST(m.county_code AS INT) AS VARCHAR(5)), 5)  AS fips,
    TRY_CAST(m.[year] AS SMALLINT)            AS year_id,
    AVG(TRY_CAST(m.arithmetic_mean AS FLOAT)) AS pm25_annual_ugm3,
    AVG(TRY_CAST(m.ninety_eighth_percentile AS FLOAT)) AS pm25_98p_ugm3,
    COUNT(*)                                  AS n_pm_monitors
FROM raw.aqs_monitor AS m
WHERE TRY_CAST(m.state_code AS INT) = 6
  AND TRY_CAST(m.parameter_code AS INT) = 88101
  AND m.sample_duration LIKE N'24-HR%'
  AND TRY_CAST(m.observation_percent AS FLOAT) >= 75
GROUP BY
    RIGHT('00000'
        + CAST(TRY_CAST(m.state_code AS INT)*1000
             + TRY_CAST(m.county_code AS INT) AS VARCHAR(5)), 5),
    TRY_CAST(m.[year] AS SMALLINT);
GO

-- Ozone county-year (param=44201, 8-hr running)
IF OBJECT_ID('stg.ozone_county','U') IS NOT NULL DROP TABLE stg.ozone_county;
CREATE TABLE stg.ozone_county (
    fips    CHAR(5)  NOT NULL,
    year_id SMALLINT NOT NULL,
    o3_dv_ppm FLOAT NULL,
    n_o3_monitors INT NULL,
    CONSTRAINT PK_stg_o3 PRIMARY KEY (fips, year_id)
);
INSERT INTO stg.ozone_county
SELECT
    RIGHT('00000'
        + CAST(TRY_CAST(m.state_code AS INT)*1000
             + TRY_CAST(m.county_code AS INT) AS VARCHAR(5)), 5),
    TRY_CAST(m.[year] AS SMALLINT),
    AVG(TRY_CAST(m.fourth_max_value AS FLOAT)),
    COUNT(*)
FROM raw.aqs_monitor AS m
WHERE TRY_CAST(m.state_code AS INT) = 6
  AND TRY_CAST(m.parameter_code AS INT) = 44201
  AND m.sample_duration LIKE N'8-HR%'
  AND TRY_CAST(m.observation_percent AS FLOAT) >= 75
GROUP BY
    RIGHT('00000'
        + CAST(TRY_CAST(m.state_code AS INT)*1000
             + TRY_CAST(m.county_code AS INT) AS VARCHAR(5)), 5),
    TRY_CAST(m.[year] AS SMALLINT);
GO

------------------------------------------------------------------
-- 9. State-level gasoline (CDTFA fuel_tax_stats.csv, fiscal year)
------------------------------------------------------------------
IF OBJECT_ID('raw.fuel_tax','U') IS NOT NULL DROP TABLE raw.fuel_tax;
CREATE TABLE raw.fuel_tax (
    fiscal_year_from NVARCHAR(8),
    fiscal_year_to   NVARCHAR(8),
    gas_gallons      NVARCHAR(32),
    gas_tax_rate     NVARCHAR(32),
    gas_revenue      NVARCHAR(32),
    gas_refund       NVARCHAR(32),
    gas_taxpayers    NVARCHAR(16)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'data_root')
                          + N'\gasoline_consumption\fuel_tax_stats.csv';
EXEC dbo.usp_bulk_load N'raw.fuel_tax', @p;
GO

------------------------------------------------------------------
-- 10. EIA SEDS gasoline price (eia_seds_gasoline_ca.csv)
------------------------------------------------------------------
IF OBJECT_ID('raw.eia_seds','U') IS NOT NULL DROP TABLE raw.eia_seds;
CREATE TABLE raw.eia_seds (
    period             NVARCHAR(8),
    stateId            NVARCHAR(8),
    seriesId           NVARCHAR(16),
    seriesDescription  NVARCHAR(256),
    [value]            NVARCHAR(32),
    [unit]             NVARCHAR(64),
    gallons            NVARCHAR(32)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'data_root')
                          + N'\gasoline_consumption\eia_seds_gasoline_ca.csv';
EXEC dbo.usp_bulk_load N'raw.eia_seds', @p;
GO

------------------------------------------------------------------
-- 11. ACS sociodemographics (census_acs_county_data.csv)
------------------------------------------------------------------
IF OBJECT_ID('raw.acs','U') IS NOT NULL DROP TABLE raw.acs;
CREATE TABLE raw.acs (
    county_name                  NVARCHAR(64),
    median_hh_income             NVARCHAR(32),
    total_population             NVARCHAR(32),
    pop_white_non_hispanic       NVARCHAR(32),
    pop_hispanic_any_race        NVARCHAR(32),
    pop_black_non_hispanic       NVARCHAR(32),
    housing_units_total          NVARCHAR(32),
    housing_units_owner_occupied NVARCHAR(32),
    commuters_total              NVARCHAR(32),
    commuters_drove_alone        NVARCHAR(32),
    hh_income_total              NVARCHAR(32),
    hh_income_under_10k          NVARCHAR(32),
    hh_income_10k_to_14999       NVARCHAR(32),
    hh_income_15k_to_19999       NVARCHAR(32),
    hh_income_20k_to_24999       NVARCHAR(32),
    hh_income_25k_to_29999       NVARCHAR(32),
    hh_income_30k_to_34999       NVARCHAR(32),
    hh_income_35k_to_39999       NVARCHAR(32),
    hh_income_40k_to_44999       NVARCHAR(32),
    hh_income_45k_to_49999       NVARCHAR(32),
    hh_income_50k_to_59999       NVARCHAR(32),
    hh_income_60k_to_74999       NVARCHAR(32),
    hh_income_75k_to_99999       NVARCHAR(32),
    hh_income_100k_to_124999     NVARCHAR(32),
    hh_income_125k_to_149999     NVARCHAR(32),
    hh_income_150k_to_199999     NVARCHAR(32),
    hh_income_200k_and_over      NVARCHAR(32),
    state_fips                   NVARCHAR(8),
    county_fips                  NVARCHAR(8),
    share_under_150k             NVARCHAR(32)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'data_root')
                          + N'\sociodemographic\census_acs_county_data.csv';
EXEC dbo.usp_bulk_load N'raw.acs', @p;
GO

IF OBJECT_ID('stg.acs_one','U') IS NOT NULL DROP TABLE stg.acs_one;
CREATE TABLE stg.acs_one (
    fips                 CHAR(5) NOT NULL PRIMARY KEY,
    median_hh_income     FLOAT   NULL,
    total_population     BIGINT  NULL,
    log_med_hh_inc       FLOAT   NULL,
    log_population       FLOAT   NULL,
    share_white_nh       FLOAT   NULL,
    share_hispanic       FLOAT   NULL,
    share_black          FLOAT   NULL,
    share_owner_occupied FLOAT   NULL,
    share_drove_alone    FLOAT   NULL,
    share_under_150k     FLOAT   NULL
);
INSERT INTO stg.acs_one
SELECT
    RIGHT('00000'
        + CAST(TRY_CAST(state_fips AS INT)*1000
             + TRY_CAST(county_fips AS INT) AS VARCHAR(5)), 5) AS fips,
    TRY_CAST(median_hh_income AS FLOAT),
    TRY_CAST(total_population AS BIGINT),
    LOG(NULLIF(TRY_CAST(median_hh_income AS FLOAT), 0)),
    LOG(NULLIF(TRY_CAST(total_population AS FLOAT), 0)),
    TRY_CAST(pop_white_non_hispanic AS FLOAT)
        / NULLIF(TRY_CAST(total_population AS FLOAT), 0),
    TRY_CAST(pop_hispanic_any_race AS FLOAT)
        / NULLIF(TRY_CAST(total_population AS FLOAT), 0),
    TRY_CAST(pop_black_non_hispanic AS FLOAT)
        / NULLIF(TRY_CAST(total_population AS FLOAT), 0),
    TRY_CAST(housing_units_owner_occupied AS FLOAT)
        / NULLIF(TRY_CAST(housing_units_total AS FLOAT), 0),
    TRY_CAST(commuters_drove_alone AS FLOAT)
        / NULLIF(TRY_CAST(commuters_total AS FLOAT), 0),
    TRY_CAST(share_under_150k AS FLOAT)
FROM raw.acs
WHERE TRY_CAST(state_fips AS INT) = 6
  AND TRY_CAST(county_fips AS INT) IS NOT NULL;
GO

------------------------------------------------------------------
-- 12. Rural-urban continuum (cleaned _clean\rural_classification.csv)
------------------------------------------------------------------
IF OBJECT_ID('raw.rucc','U') IS NOT NULL DROP TABLE raw.rucc;
CREATE TABLE raw.rucc (
    FIPS NVARCHAR(8),
    State NVARCHAR(8),
    County_Name NVARCHAR(96),
    Attribute NVARCHAR(64),
    [Value] NVARCHAR(64)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'clean_root')
                          + N'\rural_classification.csv';
EXEC dbo.usp_bulk_load N'raw.rucc', @p;
GO

IF OBJECT_ID('stg.rucc','U') IS NOT NULL DROP TABLE stg.rucc;
CREATE TABLE stg.rucc (
    fips      CHAR(5) NOT NULL PRIMARY KEY,
    rucc_code TINYINT NULL
);
INSERT INTO stg.rucc
SELECT RIGHT('00000' + LTRIM(RTRIM(FIPS)), 5) AS fips,
       TRY_CAST([Value] AS TINYINT)
FROM   raw.rucc
WHERE  State = 'CA' AND Attribute = 'RUCC_2023';
GO

------------------------------------------------------------------
-- 13. Vehicle fuel-type counts by ZIP (vehicle_fuel_type_counts_2025.csv)
------------------------------------------------------------------
IF OBJECT_ID('raw.vehicle_fuel','U') IS NOT NULL DROP TABLE raw.vehicle_fuel;
CREATE TABLE raw.vehicle_fuel (
    Date       NVARCHAR(16),
    ZIP_Code   NVARCHAR(16),
    Model_Year NVARCHAR(8),
    Fuel       NVARCHAR(32),
    Make       NVARCHAR(64),
    Duty       NVARCHAR(16),
    Vehicles   NVARCHAR(16)
);
GO
DECLARE @p NVARCHAR(500) = (SELECT v FROM dbo.cfg WHERE k=N'data_root')
                          + N'\zev_registrations_fleet_composition\vehicle_fuel_type_counts_2025.csv';
EXEC dbo.usp_bulk_load N'raw.vehicle_fuel', @p;
GO

IF OBJECT_ID('stg.veh_county_year','U') IS NOT NULL DROP TABLE stg.veh_county_year;
CREATE TABLE stg.veh_county_year (
    fips        CHAR(5)  NOT NULL,
    year_id     SMALLINT NOT NULL,
    zev_count   BIGINT   NULL,
    total_vehicles BIGINT NULL,
    zev_share   FLOAT    NULL,
    CONSTRAINT PK_stg_veh PRIMARY KEY (fips, year_id)
);
INSERT INTO stg.veh_county_year
SELECT
    z.fips,
    YEAR(TRY_CONVERT(DATE, v.Date, 101)) AS year_id,
    SUM(CASE WHEN v.Fuel IN ('Battery Electric','Plug-in Hybrid','Hydrogen Fuel Cell')
             THEN TRY_CAST(v.Vehicles AS BIGINT) ELSE 0 END) AS zev_count,
    SUM(TRY_CAST(v.Vehicles AS BIGINT))                    AS total_vehicles,
    CAST(SUM(CASE WHEN v.Fuel IN ('Battery Electric','Plug-in Hybrid','Hydrogen Fuel Cell')
                  THEN TRY_CAST(v.Vehicles AS BIGINT) ELSE 0 END) AS FLOAT)
       / NULLIF(CAST(SUM(TRY_CAST(v.Vehicles AS BIGINT)) AS FLOAT), 0)
                                                            AS zev_share
FROM raw.vehicle_fuel  AS v
JOIN dim.zip_to_county AS z
  ON z.zip = LEFT(LTRIM(RTRIM(ISNULL(v.ZIP_Code,''))), 5)
WHERE z.is_primary = 1
  AND v.Duty       = 'Light'
  AND TRY_CONVERT(DATE, v.Date, 101) IS NOT NULL
GROUP BY z.fips, YEAR(TRY_CONVERT(DATE, v.Date, 101));
GO

------------------------------------------------------------------
-- 14. fact.ev_county_year (running cumulative DCFC + L2)
------------------------------------------------------------------
IF OBJECT_ID('fact.ev_county_year','U') IS NOT NULL DROP TABLE fact.ev_county_year;
;WITH opens AS (
    SELECT fips,
           YEAR(open_date) AS year_id,
           SUM(dcfc_n)     AS dcfc_opened,
           SUM(l2_n)       AS l2_opened
    FROM   stg.ev_stations
    GROUP  BY fips, YEAR(open_date)
),
grid AS (
    SELECT c.fips, y.year_id
    FROM   dim.county c CROSS JOIN dim.year y
),
joined AS (
    SELECT g.fips, g.year_id,
           ISNULL(o.dcfc_opened, 0) AS dcfc_opened,
           ISNULL(o.l2_opened,   0) AS l2_opened
    FROM   grid g
    LEFT JOIN opens o
      ON o.fips = g.fips AND o.year_id = g.year_id
)
SELECT fips, year_id, dcfc_opened, l2_opened,
       SUM(dcfc_opened) OVER (PARTITION BY fips ORDER BY year_id
                              ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                AS dcfc_cum,
       SUM(l2_opened) OVER (PARTITION BY fips ORDER BY year_id
                            ROWS BETWEEN UNBOUNDED PRECEDING AND CURRENT ROW)
                                                AS l2_cum
INTO fact.ev_county_year
FROM joined;

CREATE UNIQUE INDEX UX_fact_ev ON fact.ev_county_year (fips, year_id);
GO

------------------------------------------------------------------
-- 15. fact.ev_dose_pretreat (cross-sectional dose D_c, winsorized 1/99)
------------------------------------------------------------------
IF OBJECT_ID('fact.ev_dose_pretreat','U') IS NOT NULL DROP TABLE fact.ev_dose_pretreat;
;WITH cum2021 AS (
    SELECT fips, dcfc_cum AS dcfc_2021, l2_cum AS l2_2021
    FROM   fact.ev_county_year
    WHERE  year_id = 2021
),
pop AS (
    SELECT fips, total_population FROM stg.acs_one
)
SELECT
    c.fips,
    CAST(ISNULL(d.dcfc_2021,0) AS FLOAT)
        / NULLIF(CAST(p.total_population AS FLOAT)/10000.0, 0) AS dose_dcfc_pc,
    CAST(ISNULL(d.l2_2021,0)   AS FLOAT)
        / NULLIF(CAST(p.total_population AS FLOAT)/10000.0, 0) AS dose_l2_pc,
    CAST(ISNULL(d.dcfc_2021,0) AS FLOAT)
        / NULLIF(CAST(ISNULL(d.dcfc_2021,0)+ISNULL(d.l2_2021,0) AS FLOAT), 0) AS share_dcfc
INTO fact.ev_dose_pretreat
FROM dim.county AS c
LEFT JOIN cum2021 AS d ON d.fips = c.fips
LEFT JOIN pop     AS p ON p.fips = c.fips;

-- Winsorize at 1st / 99th percentiles
;WITH q AS (
    SELECT DISTINCT
        PERCENTILE_CONT(0.01) WITHIN GROUP (ORDER BY dose_dcfc_pc) OVER () AS p01,
        PERCENTILE_CONT(0.99) WITHIN GROUP (ORDER BY dose_dcfc_pc) OVER () AS p99
    FROM   fact.ev_dose_pretreat
)
UPDATE d
SET    d.dose_dcfc_pc =
       CASE WHEN d.dose_dcfc_pc < q.p01 THEN q.p01
            WHEN d.dose_dcfc_pc > q.p99 THEN q.p99
            ELSE d.dose_dcfc_pc END
FROM   fact.ev_dose_pretreat AS d
CROSS  JOIN q;

CREATE UNIQUE INDEX UX_fact_dose ON fact.ev_dose_pretreat (fips);
GO

------------------------------------------------------------------
-- 16. fact.gasoline_county_year (state CDTFA gallons -> county by pop share)
------------------------------------------------------------------
IF OBJECT_ID('fact.gasoline_county_year','U') IS NOT NULL
    DROP TABLE fact.gasoline_county_year;

;WITH ft AS (
    SELECT TRY_CAST(fiscal_year_from AS INT) AS fy_from,
           TRY_CAST(fiscal_year_to   AS INT) AS fy_to,
           TRY_CAST(gas_gallons      AS FLOAT) AS gallons
    FROM raw.fuel_tax
),
cal AS (
    SELECT y.year_id,
           ISNULL((SELECT 0.5*SUM(gallons) FROM ft WHERE ft.fy_to   = y.year_id), 0)
         + ISNULL((SELECT 0.5*SUM(gallons) FROM ft WHERE ft.fy_from = y.year_id), 0)
                                                AS state_gallons
    FROM dim.year y
),
total_pop AS (
    SELECT SUM(total_population) AS pop_state FROM stg.acs_one
),
pop_share AS (
    SELECT a.fips,
           CAST(a.total_population AS FLOAT) / NULLIF((SELECT pop_state FROM total_pop),0)
                                                AS pop_share
    FROM   stg.acs_one a
),
grid AS (
    SELECT c.fips, y.year_id FROM dim.county c CROSS JOIN dim.year y
)
SELECT
    g.fips, g.year_id,
    ISNULL(cal.state_gallons, 0) * ISNULL(ps.pop_share, 0) AS gasoline_gallons
INTO fact.gasoline_county_year
FROM grid g
LEFT JOIN cal       ON cal.year_id = g.year_id
LEFT JOIN pop_share ps ON ps.fips  = g.fips;

CREATE UNIQUE INDEX UX_fact_gas ON fact.gasoline_county_year (fips, year_id);
GO

------------------------------------------------------------------
-- 17. fact.energy_prices_year (gasoline price from EIA SEDS)
------------------------------------------------------------------
IF OBJECT_ID('fact.energy_prices_year','U') IS NOT NULL
    DROP TABLE fact.energy_prices_year;

SELECT
    y.year_id,
    MAX(CASE WHEN s.seriesId = 'MGACD'
             THEN TRY_CAST(s.[value] AS FLOAT) END) AS gas_price_dollars_per_mmbtu,
    MAX(CASE WHEN s.seriesId = 'MGACD'
             THEN TRY_CAST(s.gallons AS FLOAT) END) AS gas_gallons_eia
INTO fact.energy_prices_year
FROM dim.year y
LEFT JOIN raw.eia_seds s
  ON TRY_CAST(s.period AS INT) = y.year_id AND s.stateId = 'CA'
GROUP BY y.year_id;
GO

------------------------------------------------------------------
-- 18. analytic.panel_county_year  (the single deliverable)
------------------------------------------------------------------
IF OBJECT_ID('analytic.panel_county_year','U') IS NOT NULL
    DROP TABLE analytic.panel_county_year;

;WITH skeleton AS (
    SELECT c.fips, y.year_id, y.post_nevi, y.post_obbba, y.obbba_weight
    FROM   dim.county c CROSS JOIN dim.year y
)
SELECT
    s.fips,
    s.year_id,
    -- ---------- OUTCOMES -----------------------------------------
    g.gasoline_gallons,
    CAST(g.gasoline_gallons AS FLOAT) / NULLIF(a.total_population, 0)
                                                       AS gasoline_pc,
    LOG(NULLIF(CAST(g.gasoline_gallons AS FLOAT)
               / NULLIF(a.total_population, 0), 0))    AS log_gasoline_pc,
    pm.pm25_annual_ugm3,
    LOG(NULLIF(pm.pm25_annual_ugm3, 0))                AS log_pm25,
    oz.o3_dv_ppm,
    aqi.median_aqi,
    aqi.p90_aqi,
    aqi.max_aqi,
    aqi.days_pm25,
    aqi.days_ozone,
    -- ---------- TREATMENT (dose x post indicators) ----------------
    d.dose_dcfc_pc,
    d.dose_l2_pc,
    d.share_dcfc,
    CAST(s.post_nevi  AS TINYINT)                       AS post_nevi,
    CAST(s.post_obbba AS TINYINT)                       AS post_obbba,
    CAST(s.obbba_weight AS FLOAT)                       AS obbba_weight,
    d.dose_dcfc_pc * CAST(s.post_nevi  AS FLOAT)        AS dose_x_post_nevi,
    d.dose_dcfc_pc * CAST(s.post_obbba AS FLOAT)        AS dose_x_post_obbba,
    d.dose_dcfc_pc * CAST(s.obbba_weight AS FLOAT)      AS dose_x_post_obbba_w,
    POWER(d.dose_dcfc_pc, 2) * CAST(s.post_nevi AS FLOAT)
                                                       AS dose_sq_x_post_nevi,
    -- ---------- COVARIATES X_ct -----------------------------------
    a.median_hh_income,
    a.total_population,
    a.log_med_hh_inc,
    a.log_population,
    a.share_under_150k,
    a.share_white_nh,
    a.share_hispanic,
    a.share_black,
    a.share_owner_occupied,
    a.share_drove_alone,
    r.rucc_code,
    ep.gas_price_dollars_per_mmbtu,
    -- ---------- MEDIATION / SECONDARY -----------------------------
    v.zev_share,
    v.zev_count,
    v.total_vehicles,
    -- ---------- HELPERS -------------------------------------------
    c.centroid_lat,
    c.centroid_lon,
    c.county_name
INTO analytic.panel_county_year
FROM   skeleton                 AS s
JOIN   dim.county               AS c   ON c.fips   = s.fips
LEFT  JOIN fact.gasoline_county_year AS g  ON g.fips = s.fips AND g.year_id = s.year_id
LEFT  JOIN stg.pm25_county      AS pm  ON pm.fips  = s.fips AND pm.year_id = s.year_id
LEFT  JOIN stg.ozone_county     AS oz  ON oz.fips  = s.fips AND oz.year_id = s.year_id
LEFT  JOIN stg.aqi_county       AS aqi ON aqi.fips = s.fips AND aqi.year_id = s.year_id
LEFT  JOIN stg.acs_one          AS a   ON a.fips   = s.fips
LEFT  JOIN stg.veh_county_year  AS v   ON v.fips   = s.fips AND v.year_id  = s.year_id
LEFT  JOIN stg.rucc             AS r   ON r.fips   = s.fips
LEFT  JOIN fact.ev_dose_pretreat AS d  ON d.fips   = s.fips
LEFT  JOIN fact.energy_prices_year AS ep ON ep.year_id = s.year_id;

CREATE UNIQUE INDEX UX_panel ON analytic.panel_county_year (fips, year_id);
CREATE INDEX        IX_panel_year ON analytic.panel_county_year (year_id);
GO

------------------------------------------------------------------
-- 19. Integrity checks
------------------------------------------------------------------
PRINT '--- Row count ---';
SELECT COUNT(*) AS n_rows,
       COUNT(DISTINCT fips) AS n_counties,
       MIN(year_id) AS year_min, MAX(year_id) AS year_max
FROM   analytic.panel_county_year;

PRINT '--- Missingness on headline outcomes / dose ---';
SELECT
    SUM(CASE WHEN log_gasoline_pc   IS NULL THEN 1 ELSE 0 END) AS miss_log_gas_pc,
    SUM(CASE WHEN pm25_annual_ugm3  IS NULL THEN 1 ELSE 0 END) AS miss_pm25,
    SUM(CASE WHEN o3_dv_ppm         IS NULL THEN 1 ELSE 0 END) AS miss_o3,
    SUM(CASE WHEN dose_dcfc_pc      IS NULL THEN 1 ELSE 0 END) AS miss_dose,
    SUM(CASE WHEN log_med_hh_inc    IS NULL THEN 1 ELSE 0 END) AS miss_inc
FROM analytic.panel_county_year;

PRINT '--- Top 5 dose counties (2022) ---';
SELECT TOP 5 county_name, dose_dcfc_pc
FROM   analytic.panel_county_year
WHERE  year_id = 2022 ORDER BY dose_dcfc_pc DESC;

PRINT '--- Bottom 5 dose counties (2022) ---';
SELECT TOP 5 county_name, dose_dcfc_pc
FROM   analytic.panel_county_year
WHERE  year_id = 2022 ORDER BY dose_dcfc_pc ASC;
GO

PRINT 'analytic.panel_county_year ready for Python / R.';
GO
