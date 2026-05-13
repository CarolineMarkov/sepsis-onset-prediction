# Sepsis Onset Prediction Using MIMIC-IV

Bachelor’s thesis repository for machine learning-based early sepsis prediction using MIMIC-IV clinical data.

## Project Overview

This project investigates early sepsis onset prediction in ICU patients using machine learning models trained on MIMIC-IV electronic health record data. The study compares full clinical feature sets with reduced wearable-compatible feature sets and evaluates both admission-anchored and sliding window prediction frameworks.

## Repository Structure

```text
sql/
    build_final_features.sql     BigQuery feature extraction pipeline

notebooks/
    01_preprocessing.ipynb
    02_baseline.ipynb
    03_baseline_balanced.ipynb
    04_sliding_window.ipynb
    05_results_analysis.ipynb
```

## Data Access

This project uses the MIMIC-IV database hosted on PhysioNet.

MIMIC-IV data cannot be shared publicly due to PhysioNet data use restrictions. Users must independently obtain credentialed access through PhysioNet and Google BigQuery.

PhysioNet:
https://physionet.org/

MIMIC-IV:
https://physionet.org/content/mimiciv/

## Derived Concepts

Some derived concepts used in this project are based on the official MIT-LCP MIMIC Code Repository and MIMIC-IV derived dataset, including:
- `icustay_hourly`
- `gcs`
- `sepsis3`

MIMIC Code Repository:
https://github.com/MIT-LCP/mimic-code

## Models

The project evaluates:
- LightGBM
- XGBoost
- Random Forest

Evaluation metrics include:
- AUROC
- PR-AUC
- Sensitivity
- Specificity
- Precision
- F1-score
- Brier score

## Citation

Johnson, A. E. W., Stone, D. J., Celi, L. A., & Pollard, T. J. (2018). *The MIMIC Code Repository: enabling reproducibility in critical care research*. Journal of the American Medical Informatics Association, 25(1), 32–39.
