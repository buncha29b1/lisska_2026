.PHONY: install_twfe_deps build_panel twfe cross_validate clean_twfe_outputs

install_twfe_deps:
	python -m pip install -r requirements-twfe.txt

build_panel:
	python build_twfe_model.py

twfe: build_panel

cross_validate: build_panel
	Rscript cross_validate_twfe.R

clean_twfe_outputs:
	rm -f ca_county_year_panel.csv ca_county_year_panel.parquet twfe_python_results.csv twfe_r_results.csv twfe_python_r_comparison.csv twfe_panel_diagnostics.json
