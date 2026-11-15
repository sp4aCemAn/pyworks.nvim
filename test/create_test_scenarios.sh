#!/bin/bash

# Create test scenarios for pyworks.nvim
# This script creates a comprehensive test structure

echo "🏗️ Creating Pyworks Test Scenarios..."

# Override with PYWORKS_SCENARIOS_DIR (the container harness generates under
# /sandbox, OUTSIDE the repo — otherwise the plugin's own pyproject.toml
# marker leaks into every scenario that has no marker of its own).
BASE_DIR="${PYWORKS_SCENARIOS_DIR:-$(dirname "$0")/scenarios}"
rm -rf "$BASE_DIR" 2>/dev/null
mkdir -p "$BASE_DIR"

# Write a minimal, spec-valid nbformat 4.5 notebook. (Omitting the nbformat
# field makes jupytext crash with AttributeError, which previously broke all
# notebook fixtures.) Usage: write_notebook path [source_cell]
write_notebook() {
	local path="$1" cell="${2:-}"
	if [ -n "$cell" ]; then
		cat >"$path" <<EOF
{"cells": [{"cell_type": "code", "id": "a1b2c3d4", "metadata": {}, "execution_count": null, "outputs": [], "source": ["$cell"]}], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python", "version": "3.12.0"}}, "nbformat": 4, "nbformat_minor": 5}
EOF
	else
		cat >"$path" <<EOF
{"cells": [], "metadata": {"kernelspec": {"display_name": "Python 3", "language": "python", "name": "python3"}, "language_info": {"name": "python", "version": "3.12.0"}}, "nbformat": 4, "nbformat_minor": 5}
EOF
	fi
}

# ==============================================================================
# PYTHON BASIC SCENARIOS
# ==============================================================================

echo "📦 Creating Python basic scenarios..."

# 1.1 Simple Python file (no markers)
mkdir -p "$BASE_DIR/01_python_simple"
cat >"$BASE_DIR/01_python_simple/hello.py" <<'EOF'
# Simple Python file with no project markers
print("Hello World")
EOF

# 1.2 Python with existing venv
mkdir -p "$BASE_DIR/02_python_with_venv/.venv/bin"
touch "$BASE_DIR/02_python_with_venv/.venv/bin/python"
cat >"$BASE_DIR/02_python_with_venv/main.py" <<'EOF'
# Python file with existing venv
import numpy as np
print("Has venv")
EOF

# 1.3 Nested Python with parent venv
mkdir -p "$BASE_DIR/03_python_nested/.venv/bin"
mkdir -p "$BASE_DIR/03_python_nested/src/utils"
touch "$BASE_DIR/03_python_nested/.venv/bin/python"
cat >"$BASE_DIR/03_python_nested/src/utils/helper.py" <<'EOF'
# Nested file should find parent venv
def process_data():
    return "processed"
EOF

# ==============================================================================
# WEB FRAMEWORK SCENARIOS
# ==============================================================================

echo "🌐 Creating web framework scenarios..."

# 1.4 Django project
mkdir -p "$BASE_DIR/04_django_project/myapp/views"
mkdir -p "$BASE_DIR/04_django_project/notebooks/analysis"
cat >"$BASE_DIR/04_django_project/manage.py" <<'EOF'
#!/usr/bin/env python
import os
import sys

if __name__ == '__main__':
    os.environ.setdefault('DJANGO_SETTINGS_MODULE', 'myapp.settings')
    from django.core.management import execute_from_command_line
    execute_from_command_line(sys.argv)
EOF
cat >"$BASE_DIR/04_django_project/requirements.txt" <<'EOF'
django==4.2.0
pandas==2.0.0
EOF
cat >"$BASE_DIR/04_django_project/myapp/views/user.py" <<'EOF'
from django.views import View

class UserView(View):
    pass
EOF
write_notebook "$BASE_DIR/04_django_project/notebooks/analysis/explore.ipynb"

# 1.5 Flask project
mkdir -p "$BASE_DIR/05_flask_project/routes"
cat >"$BASE_DIR/05_flask_project/app.py" <<'EOF'
from flask import Flask
app = Flask(__name__)

@app.route('/')
def hello():
    return "Hello Flask"
EOF
cat >"$BASE_DIR/05_flask_project/requirements.txt" <<'EOF'
flask==2.3.0
sqlalchemy==2.0.0
EOF
cat >"$BASE_DIR/05_flask_project/routes/auth.py" <<'EOF'
from flask import Blueprint
auth_bp = Blueprint('auth', __name__)
EOF

# 1.6 FastAPI project
mkdir -p "$BASE_DIR/06_fastapi_project/api/endpoints"
mkdir -p "$BASE_DIR/06_fastapi_project/ml/models"
cat >"$BASE_DIR/06_fastapi_project/main.py" <<'EOF'
from fastapi import FastAPI
from pydantic import BaseModel

app = FastAPI()

@app.get("/")
def read_root():
    return {"Hello": "FastAPI"}
EOF
cat >"$BASE_DIR/06_fastapi_project/requirements.txt" <<'EOF'
fastapi==0.100.0
uvicorn==0.23.0
scikit-learn==1.3.0
EOF
cat >"$BASE_DIR/06_fastapi_project/api/endpoints/predict.py" <<'EOF'
from fastapi import APIRouter
router = APIRouter()

@router.post("/predict")
def predict():
    return {"prediction": 0.95}
EOF

# 1.7 Streamlit project
mkdir -p "$BASE_DIR/07_streamlit_project/pages"
mkdir -p "$BASE_DIR/07_streamlit_project/data"
cat >"$BASE_DIR/07_streamlit_project/app.py" <<'EOF'
import streamlit as st
import pandas as pd

st.title("Data Dashboard")
st.write("Welcome to Streamlit")
EOF
cat >"$BASE_DIR/07_streamlit_project/requirements.txt" <<'EOF'
streamlit==1.25.0
plotly==5.15.0
EOF
cat >"$BASE_DIR/07_streamlit_project/pages/analysis.py" <<'EOF'
import streamlit as st
st.header("Analysis Page")
EOF

# ==============================================================================
# PACKAGE MANAGEMENT SCENARIOS
# ==============================================================================

echo "📚 Creating package management scenarios..."

# 1.8 Poetry project
mkdir -p "$BASE_DIR/08_poetry_project/src/mypackage"
cat >"$BASE_DIR/08_poetry_project/pyproject.toml" <<'EOF'
[tool.poetry]
name = "mypackage"
version = "0.1.0"
description = "Poetry managed project"

[tool.poetry.dependencies]
python = "^3.9"
requests = "^2.31.0"
EOF
cat >"$BASE_DIR/08_poetry_project/src/mypackage/core.py" <<'EOF'
def main():
    return "Poetry project"
EOF

# 1.9 Pipenv project
mkdir -p "$BASE_DIR/09_pipenv_project/app"
cat >"$BASE_DIR/09_pipenv_project/Pipfile" <<'EOF'
[[source]]
url = "https://pypi.org/simple"
verify_ssl = true
name = "pypi"

[packages]
requests = "*"
flask = "*"

[dev-packages]
pytest = "*"
EOF
cat >"$BASE_DIR/09_pipenv_project/app/main.py" <<'EOF'
import requests
print("Pipenv project")
EOF

# 1.10 Conda project
mkdir -p "$BASE_DIR/10_conda_project/notebooks"
cat >"$BASE_DIR/10_conda_project/environment.yml" <<'EOF'
name: myenv
channels:
  - conda-forge
dependencies:
  - python=3.9
  - numpy
  - pandas
  - scikit-learn
EOF
cat >"$BASE_DIR/10_conda_project/analysis.py" <<'EOF'
import numpy as np
import pandas as pd
print("Conda project")
EOF

# ==============================================================================
# MLOPS SCENARIOS
# ==============================================================================

echo "🤖 Creating MLOps scenarios..."

# 1.13 DVC project
mkdir -p "$BASE_DIR/13_dvc_project/data"
mkdir -p "$BASE_DIR/13_dvc_project/notebooks/eda"
mkdir -p "$BASE_DIR/13_dvc_project/src"
cat >"$BASE_DIR/13_dvc_project/dvc.yaml" <<'EOF'
stages:
  prepare:
    cmd: python src/prepare.py
    deps:
      - data/raw
    outs:
      - data/processed
  train:
    cmd: python src/train.py
    deps:
      - data/processed
    outs:
      - models/model.pkl
EOF
cat >"$BASE_DIR/13_dvc_project/requirements.txt" <<'EOF'
dvc==3.0.0
scikit-learn==1.3.0
pandas==2.0.0
EOF
cat >"$BASE_DIR/13_dvc_project/src/train.py" <<'EOF'
# ML training pipeline
from sklearn.ensemble import RandomForestClassifier
print("Training model...")
EOF
write_notebook "$BASE_DIR/13_dvc_project/notebooks/eda/explore.ipynb"

# 1.14 MLflow project
mkdir -p "$BASE_DIR/14_mlflow_project/experiments"
cat >"$BASE_DIR/14_mlflow_project/MLproject" <<'EOF'
name: my_model

conda_env: conda.yaml

entry_points:
  main:
    parameters:
      alpha: {type: float, default: 0.5}
    command: "python train.py --alpha {alpha}"
EOF
cat >"$BASE_DIR/14_mlflow_project/conda.yaml" <<'EOF'
name: mlflow-env
channels:
  - defaults
dependencies:
  - python=3.9
  - mlflow
  - scikit-learn
EOF
cat >"$BASE_DIR/14_mlflow_project/train.py" <<'EOF'
import mlflow
import mlflow.sklearn
print("MLflow project")
EOF

# ==============================================================================
# NOTEBOOK SCENARIOS
# ==============================================================================

echo "📓 Creating notebook scenarios..."

# 2.1 Standalone notebook
mkdir -p "$BASE_DIR/21_standalone_notebook"
write_notebook "$BASE_DIR/21_standalone_notebook/analysis.ipynb" 'print(\"hello from fixture\")'

# 2.4 Django with notebooks (deeply nested)
mkdir -p "$BASE_DIR/24_django_notebooks/backend/apps/analytics/views"
mkdir -p "$BASE_DIR/24_django_notebooks/research/notebooks/experiments/2024"
cat >"$BASE_DIR/24_django_notebooks/manage.py" <<'EOF'
#!/usr/bin/env python
import django
EOF
cat >"$BASE_DIR/24_django_notebooks/requirements.txt" <<'EOF'
django==4.2.0
jupyter==1.0.0
pandas==2.0.0
EOF
write_notebook "$BASE_DIR/24_django_notebooks/research/notebooks/experiments/2024/q1_analysis.ipynb"

# 2.5 FastAPI with ML notebooks
mkdir -p "$BASE_DIR/25_fastapi_ml/api/v1/endpoints"
mkdir -p "$BASE_DIR/25_fastapi_ml/ml/notebooks/training"
cat >"$BASE_DIR/25_fastapi_ml/main.py" <<'EOF'
from fastapi import FastAPI
app = FastAPI(title="ML API")
EOF
write_notebook "$BASE_DIR/25_fastapi_ml/ml/notebooks/training/model_v2.ipynb"

# ==============================================================================
# EDGE CASES
# ==============================================================================

echo "🔧 Creating edge cases..."

# 3.1 Multiple markers (should prioritize .venv)
mkdir -p "$BASE_DIR/31_multiple_markers/.venv/bin"
touch "$BASE_DIR/31_multiple_markers/.venv/bin/python"
cat >"$BASE_DIR/31_multiple_markers/manage.py" <<'EOF'
# Django manage
EOF
cat >"$BASE_DIR/31_multiple_markers/requirements.txt" <<'EOF'
django==4.2.0
EOF
cat >"$BASE_DIR/31_multiple_markers/pyproject.toml" <<'EOF'
[tool.poetry]
name = "multi"
EOF
cat >"$BASE_DIR/31_multiple_markers/test.py" <<'EOF'
# Should use .venv (highest priority)
print("Multiple markers")
EOF

# 3.2 Git repository as fallback
mkdir -p "$BASE_DIR/32_git_only/.git"
cat >"$BASE_DIR/32_git_only/script.py" <<'EOF'
# Should use .git as last resort for project root
print("Git only project")
EOF

echo "✅ Test scenarios created successfully!"
echo ""
echo "📁 Test structure created at: $BASE_DIR"
echo ""
echo "🧪 To test each scenario:"
echo "   1. cd into a scenario directory"
echo "   2. Open a file with nvim"
echo "   3. Observe the pyworks detection messages"
echo ""
echo "📝 Scenarios created:"
find "$BASE_DIR" -maxdepth 1 -type d | sort | tail -n +2 | while read dir; do
  echo "   - $(basename "$dir")"
done
