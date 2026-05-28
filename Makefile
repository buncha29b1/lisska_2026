.PHONY: install_twfe_deps build_panel estimate_sql_panel twfe cross_validate clean_twfe_outputs

install_twfe_deps:
	python -m pip install -r requirements-twfe.txt

build_panel:
	python build_twfe_model.py

estimate_sql_panel:
	python build_twfe_model.py --panel-input ca_county_year_panel.csv

twfe: build_panel

cross_validate: build_panel
	Rscript cross_validate_twfe.R ca_county_year_panel.csv

clean_twfe_outputs:
	rm -f ca_county_year_panel.csv ca_county_year_panel.parquet twfe_python_results.csv twfe_r_results.csv twfe_python_r_comparison.csv twfe_panel_diagnostics.json
