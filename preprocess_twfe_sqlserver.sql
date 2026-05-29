/*
SQL Server preprocessing for the continuous-treatment TWFE panel.

Run this file in SQL Server Management Studio. SQLCMD Mode is NOT required.

Why this version is different:
- It does NOT use OPENROWSET, so it does not require Ad Hoc Distributed Queries.
- It does NOT use BULK INSERT ... FORMAT='CSV', which caused the OLE DB BULK
  provider IID_IColumnsInfo error on older/locked-down SQL Server installs.
- It loads a SQL-friendly root-level seed file, ca_county_year_panel_sql_seed.csv,
  with legacy BULK INSERT options only.

Before running, set @RepoRoot to the absolute path of this repository as seen by
SQL Server, for example:
  N'C:\Users\YourName\Documents\lisska_2026'

If SQL Server is on a different machine from SSMS, @RepoRoot must be a path on
the SQL Server machine or a UNC path that the SQL Server service account can read.
*/

SET NOCOUNT ON;

DROP TABLE IF EXISTS #twfe_config;
CREATE TABLE #twfe_config (repo_root nvarchar(4000) NOT NULL);

DECLARE @RepoRoot nvarchar(4000) = N''; -- <-- EDIT THIS ONE LINE to your absolute repo path.

-- Convenience fallback for this container/repo path. Windows SSMS users should
-- paste their own absolute Windows path in @RepoRoot above.
IF NULLIF(LTRIM(RTRIM(@RepoRoot)), N'') IS NULL
BEGIN
  SET @RepoRoot = N'/workspace/lisska_2026';
END;

WHILE RIGHT(@RepoRoot, 1) IN (N'\', N'/') SET @RepoRoot = LEFT(@RepoRoot, LEN(@RepoRoot) - 1);
INSERT INTO #twfe_config(repo_root) VALUES (@RepoRoot);

IF DB_ID(N'lisska_2026_twfe') IS NULL CREATE DATABASE lisska_2026_twfe;
GO
USE lisska_2026_twfe;
GO

DROP TABLE IF EXISTS dbo.ca_county_year_panel;
DROP TABLE IF EXISTS dbo.stg_ca_county_year_panel_seed;
GO

CREATE TABLE dbo.stg_ca_county_year_panel_seed (
  fips varchar(20) NULL,
  county nvarchar(100) NULL,
  aland varchar(100) NULL,
  [year] varchar(100) NULL,
  gasoline_gallons varchar(100) NULL,
  gasoline_pc varchar(100) NULL,
  log_gasoline_pc varchar(100) NULL,
  pm25 varchar(100) NULL,
  log_pm25 varchar(100) NULL,
  o3 varchar(100) NULL,
  log_o3 varchar(100) NULL,
  dcfc_ports_2021 varchar(100) NULL,
  l2_ports_2021 varchar(100) NULL,
  dose_dcfc_density varchar(100) NULL,
  dose_dcfc_density_sq varchar(100) NULL,
  ihs_dose_dcfc_density varchar(100) NULL,
  share_dcfc_2021 varchar(100) NULL,
  post_nevi varchar(100) NULL,
  post_obbba varchar(100) NULL,
  dose_x_post_nevi varchar(100) NULL,
  dose_sq_x_post_nevi varchar(100) NULL,
  dose_x_post_obbba varchar(100) NULL,
  median_hh_income varchar(100) NULL,
  total_population varchar(100) NULL,
  share_under_150k varchar(100) NULL,
  log_med_hh_inc varchar(100) NULL,
  log_population varchar(100) NULL,
  share_white_nh varchar(100) NULL,
  share_owner_occupied varchar(100) NULL,
  share_commute_alone varchar(100) NULL,
  rucc_2023 varchar(100) NULL,
  gasoline_price_dollars_per_mmbtu varchar(100) NULL,
  eia_gasoline_gallons varchar(100) NULL
);
GO

DECLARE @RepoRoot nvarchar(4000) = (SELECT repo_root FROM #twfe_config);
DECLARE @sep nchar(1) = CASE WHEN CHARINDEX(N'/', @RepoRoot) > 0 AND CHARINDEX(N'\', @RepoRoot) = 0 THEN N'/' ELSE N'\' END;
DECLARE @path nvarchar(4000) = @RepoRoot + @sep + N'ca_county_year_panel_sql_seed.csv';
DECLARE @sql nvarchar(max);

PRINT CONCAT('Loading SQL-friendly clean panel seed: ', @path);
SET @sql = N'BULK INSERT dbo.stg_ca_county_year_panel_seed FROM ''' + REPLACE(@path, '''', '''''') + N''' WITH (FIRSTROW = 2, FIELDTERMINATOR = '','', ROWTERMINATOR = ''0x0a'', CODEPAGE = ''65001'', TABLOCK);';
EXEC(@sql);
GO

SELECT
  RIGHT('00000' + LTRIM(RTRIM(fips)), 5) AS fips,
  county,
  TRY_CONVERT(float, NULLIF(aland, '')) AS aland,
  TRY_CONVERT(int, NULLIF([year], '')) AS [year],
  TRY_CONVERT(float, NULLIF(gasoline_gallons, '')) AS gasoline_gallons,
  TRY_CONVERT(float, NULLIF(gasoline_pc, '')) AS gasoline_pc,
  TRY_CONVERT(float, NULLIF(log_gasoline_pc, '')) AS log_gasoline_pc,
  TRY_CONVERT(float, NULLIF(pm25, '')) AS pm25,
  TRY_CONVERT(float, NULLIF(log_pm25, '')) AS log_pm25,
  TRY_CONVERT(float, NULLIF(o3, '')) AS o3,
  TRY_CONVERT(float, NULLIF(log_o3, '')) AS log_o3,
  TRY_CONVERT(float, NULLIF(dcfc_ports_2021, '')) AS dcfc_ports_2021,
  TRY_CONVERT(float, NULLIF(l2_ports_2021, '')) AS l2_ports_2021,
  TRY_CONVERT(float, NULLIF(dose_dcfc_density, '')) AS dose_dcfc_density,
  TRY_CONVERT(float, NULLIF(dose_dcfc_density_sq, '')) AS dose_dcfc_density_sq,
  TRY_CONVERT(float, NULLIF(ihs_dose_dcfc_density, '')) AS ihs_dose_dcfc_density,
  TRY_CONVERT(float, NULLIF(share_dcfc_2021, '')) AS share_dcfc_2021,
  TRY_CONVERT(int, NULLIF(post_nevi, '')) AS post_nevi,
  TRY_CONVERT(int, NULLIF(post_obbba, '')) AS post_obbba,
  TRY_CONVERT(float, NULLIF(dose_x_post_nevi, '')) AS dose_x_post_nevi,
  TRY_CONVERT(float, NULLIF(dose_sq_x_post_nevi, '')) AS dose_sq_x_post_nevi,
  TRY_CONVERT(float, NULLIF(dose_x_post_obbba, '')) AS dose_x_post_obbba,
  TRY_CONVERT(float, NULLIF(median_hh_income, '')) AS median_hh_income,
  TRY_CONVERT(float, NULLIF(total_population, '')) AS total_population,
  TRY_CONVERT(float, NULLIF(share_under_150k, '')) AS share_under_150k,
  TRY_CONVERT(float, NULLIF(log_med_hh_inc, '')) AS log_med_hh_inc,
  TRY_CONVERT(float, NULLIF(log_population, '')) AS log_population,
  TRY_CONVERT(float, NULLIF(share_white_nh, '')) AS share_white_nh,
  TRY_CONVERT(float, NULLIF(share_owner_occupied, '')) AS share_owner_occupied,
  TRY_CONVERT(float, NULLIF(share_commute_alone, '')) AS share_commute_alone,
  TRY_CONVERT(int, NULLIF(rucc_2023, '')) AS rucc_2023,
  TRY_CONVERT(float, NULLIF(gasoline_price_dollars_per_mmbtu, '')) AS gasoline_price_dollars_per_mmbtu,
  TRY_CONVERT(float, NULLIF(eia_gasoline_gallons, '')) AS eia_gasoline_gallons
INTO dbo.ca_county_year_panel
FROM dbo.stg_ca_county_year_panel_seed
WHERE NULLIF(LTRIM(RTRIM(fips)), '') IS NOT NULL;
GO

CREATE INDEX IX_ca_county_year_panel_fips_year ON dbo.ca_county_year_panel(fips, [year]);
GO

DECLARE @panel_rows int, @panel_counties int, @first_year int, @last_year int;
SELECT @panel_rows = COUNT(*), @panel_counties = COUNT(DISTINCT fips), @first_year = MIN([year]), @last_year = MAX([year])
FROM dbo.ca_county_year_panel;

IF @panel_rows = 0
BEGIN
  THROW 51000, 'dbo.ca_county_year_panel has 0 rows. Check @RepoRoot and SQL Server service-account read access to ca_county_year_panel_sql_seed.csv.', 1;
END;

PRINT CONCAT('Built dbo.ca_county_year_panel with ', @panel_rows, ' rows, ', @panel_counties, ' counties, years ', @first_year, '-', @last_year, '.');
PRINT 'The final result set below is the clean model dataset. In SSMS, save it as ca_county_year_panel.csv in the repo root, then run: python build_twfe_model.py --panel-input ca_county_year_panel.csv';
SELECT *
FROM dbo.ca_county_year_panel
ORDER BY fips, [year];
