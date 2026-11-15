# Pyworks.nvim Test Suite

This folder contains comprehensive test scenarios for pyworks.nvim's smart detection logic.

## Quick Start

**Automated (containerized, hermetic — use this):**

```bash
./test/container.sh build       # once (and when Containerfile changes)
./test/container.sh warm        # REQUIRED after build/clean — the only
                                # network-privileged step (seeds everything)
./test/container.sh unit        # plenary specs
./test/container.sh scenarios   # the 17 detection scenarios below, automated
./test/container.sh e2e         # Molten kernel smoke (2 steps red: known upstream bug)
./test/container.sh shell       # interactive nvim inside the sandbox
```

Security posture: test containers run as your host user (never root),
with the repo mounted read-only and no network egress — warm is the only
step that reaches the internet. Design, findings, and the cold-start rule:
`test/ENVIRONMENT_PLAN.md`.

**Manual (host):**

1. **Generate test scenarios:**
   ```bash
   ./create_test_scenarios.sh
   ```
   This creates a `scenarios/` folder with 20+ test cases

2. **Test a scenario:**
   ```bash
   cd scenarios/04_django_project
   nvim myapp/views/user.py
   ```

3. **What to expect:**
   - Pyworks will show project type detection
   - It will indicate where venv exists or will be created
   - For missing venv, it suggests running `:PyworksSetup`

## Test Categories

### Python Projects
- `01_python_simple` - Basic Python file, no markers
- `02_python_with_venv` - Python with existing .venv
- `03_python_nested` - Nested file with parent venv

### Web Frameworks
- `04_django_project` - Django with manage.py
- `05_flask_project` - Flask with app.py
- `06_fastapi_project` - FastAPI with main.py
- `07_streamlit_project` - Streamlit dashboard

### Package Management
- `08_poetry_project` - Poetry with pyproject.toml
- `09_pipenv_project` - Pipenv with Pipfile
- `10_conda_project` - Conda with environment.yml

### MLOps/Data Science
- `13_dvc_project` - DVC pipeline project
- `14_mlflow_project` - MLflow experiment tracking

### Notebooks
- `21_standalone_notebook` - Simple .ipynb file
- `24_django_notebooks` - Django + deeply nested notebooks
- `25_fastapi_ml` - FastAPI + ML notebooks

### Edge Cases
- `51_multiple_markers` - Multiple project markers (tests priority)

## Expected Behaviors

### With Existing Venv
```
🐍 Django project: venv at 04_django_project/.venv
```

### Without Venv
```
⚠️ FastAPI project: No venv for api/endpoints/predict.py
💡 Run :PyworksSetup to create venv at: 06_fastapi_project/.venv
```

### Notebooks in Projects
```
📓 Django notebook: venv at 04_django_project/.venv
```
Even deeply nested notebooks find the project root!

## Testing Workflow

1. Open file in test scenario
2. Check notifications (bottom of screen)
3. Try `:PyworksSetup` if no venv
4. Restart Neovim after setup
5. Verify Molten commands work

## Notes

- The `scenarios/` folder is gitignored to keep repo clean
- Run `./create_test_scenarios.sh` anytime to regenerate
- Each scenario is self-contained for easy testing
