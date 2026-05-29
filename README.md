# lisska_2026

## TWFE preprocessing and estimation workflow

All runnable code for the first continuous-treatment TWFE model lives in the repository root. The collected source data stay under `data/`, while the SQL/Python/R files read from those data-derived root artifacts and write model outputs back to the root.

1. Optional, only when raw data change: regenerate the SQL seed panel.
   ```bash
   python prepare_sql_seed_panel.py
   ```
2. In SQL Server Management Studio, run `preprocess_twfe_sqlserver.sql`. The script avoids `OPENROWSET` and `BULK INSERT`; it embeds the current 928-row seed as ordinary T-SQL `INSERT` statements to avoid the OLE DB `IID_IColumnsInfo` error.
3. Save the final SSMS result set as `ca_county_year_panel.csv` in this repo root.
4. Estimate the Python TWFE model on the SQL output.
   ```bash
   python build_twfe_model.py --panel-input ca_county_year_panel.csv
   ```
5. Cross-validate the same SQL-exported panel in R.
   ```bash
   Rscript cross_validate_twfe.R ca_county_year_panel.csv
   ```

Expected root outputs are `ca_county_year_panel.csv`, `twfe_python_results.csv`, `twfe_r_results.csv`, and `twfe_python_r_comparison.csv`.
