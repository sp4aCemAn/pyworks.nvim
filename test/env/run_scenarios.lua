-- Automated scenario suite for pyworks.nvim (container test env).
--
-- Runs INSIDE the sandbox nvim with the full plugin loaded
-- (plugin/pyworks.lua autocmds active):
--
--   1. direct API checks: utils.find_project_root + detect_project_type
--   2. detection-on-open checks: assertions against notifications the user
--      actually sees (vim.notify capture; suppressed ones never arrive)
--
-- Scenarios must live OUTSIDE the repo (PYWORKS_SCENARIOS_DIR=/sandbox/...)
-- so the plugin's own pyproject.toml marker doesn't leak into detection.
--
-- Note: `venv = "fake"` fixtures have a .venv dir with a NON-executable
-- bin/python. They exercise the kernel-probe path and deterministically
-- produce "ipykernel not found in venv" (create_venv no-ops since the dir
-- exists). Expectations encode CURRENT behavior, including known bug #2
-- (is_pyworks_project always true) — revisit those when the bug is fixed.

local base = vim.fn.fnamemodify(os.getenv("PYWORKS_SCENARIOS_DIR") or "test/scenarios", ":p")

-- name, file (relative to scenario), type, venv: "none"|"fake", notebook flag
local scenarios = {
	{ "01_python_simple", "hello.py", "Python", "none" },
	{ "02_python_with_venv", "main.py", "Python", "fake" },
	{ "03_python_nested", "src/utils/helper.py", "Python", "fake" },
	{ "04_django_project", "myapp/views/user.py", "Django", "none" },
	{ "05_flask_project", "routes/auth.py", "Flask", "none" },
	{ "06_fastapi_project", "api/endpoints/predict.py", "FastAPI", "none" },
	{ "07_streamlit_project", "pages/analysis.py", "Streamlit", "none" },
	{ "08_poetry_project", "src/mypackage/core.py", "Poetry/Modern Python", "none" },
	{ "09_pipenv_project", "app/main.py", "Python", "none" },
	{ "10_conda_project", "analysis.py", "Conda Project", "none" },
	{ "13_dvc_project", "src/train.py", "DVC/MLOps", "none" },
	{ "14_mlflow_project", "train.py", "Conda Project", "none" },
	{ "21_standalone_notebook", "analysis.ipynb", "Python", "none", true },
	{ "24_django_notebooks", "research/notebooks/experiments/2024/q1_analysis.ipynb", "Django", "none", true },
	{ "25_fastapi_ml", "ml/notebooks/training/model_v2.ipynb", "FastAPI", "none", true },
	{ "31_multiple_markers", "test.py", "Django", "fake" },
	{ "32_git_only", "script.py", "Python", "none" },
}

-- ---------------------------------------------------------------------------
-- notification capture
-- ---------------------------------------------------------------------------
local captured = {}
vim.notify = function(msg, _)
	table.insert(captured, tostring(msg))
end

-- Force notebook handler + molten config NOW. setup() defers this by 100ms,
-- which could race the first .ipynb open below.
require("pyworks").configure_dependencies({})

local utils = require("pyworks.utils")

local fails = 0
local sc_fails = 0
local function check(cond, msg)
	if not cond then
		fails = fails + 1
		sc_fails = sc_fails + 1
		print("    FAIL: " .. msg)
	end
	return cond
end

local function dump_captured()
	if sc_fails > 0 then
		local joined = table.concat(captured, " || ")
		print("    captured: " .. joined:sub(1, 700))
	end
end

local function has(needle)
	for _, m in ipairs(captured) do
		if m:find(needle, 1, true) then
			return true
		end
	end
	return false
end

local function wipe_buffers()
	local keep = vim.api.nvim_get_current_buf()
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if b ~= keep and vim.api.nvim_buf_is_valid(b) then
			pcall(vim.api.nvim_buf_delete, b, { force = true })
		end
	end
end

print(string.format("=== pyworks scenario suite (%d scenarios, base=%s) ===", #scenarios, base))

for _, sc in ipairs(scenarios) do
	local name, rel_file, want_type, venv_kind, is_nb = sc[1], sc[2], sc[3], sc[4], sc[5]
	local dir = base .. name
	local file = dir .. "/" .. rel_file

	if vim.fn.isdirectory(dir) ~= 1 then
		check(false, name .. ": scenario dir missing (did the generator run?)")
	else
		print("- " .. name)
		sc_fails = 0
		captured = {}
		wipe_buffers()
		vim.cmd("cd " .. vim.fn.fnameescape(dir))

		-- 1) direct API assertions (root must resolve to the scenario dir).
		-- trailing "/" tolerated: the cwd-fallback path in find_project_root
		-- returns fnamemodify(cwd, ":p"), which may or may not carry one.
		local function norm(p)
			return type(p) == "string" and p:gsub("/$", "") or p
		end
		local actual_root = norm(utils.find_project_root(dir))
		check(actual_root == norm(dir), name .. ": find_project_root got=" .. tostring(actual_root))
		check(utils.detect_project_type(dir) == want_type, name .. ": detect_project_type == " .. want_type)

		-- 2) detection-on-open assertions (plugin autocmds drive these).
		-- Only the WARN/ERROR notifications are user-visible: no-option INFO
		-- messages are suppressed by design (notifications.lua), so hints
		-- like "Run :PyworksSetup ..." intentionally do NOT appear here.
		vim.cmd("edit " .. vim.fn.fnameescape(file))

		local needle
		if venv_kind == "none" then
			needle = want_type .. (is_nb and " notebook: No venv for" or " project: No venv for")
			vim.wait(8000, function()
				return has(needle)
			end, 100)
			vim.wait(500)
			check(has(needle), name .. ": notification missing: " .. needle)
			check(not has("ipykernel not found in venv"), name .. ": no kernel probe expected (no venv)")
		else -- fake venv: dir exists but bin/python isn't executable
			needle = "ipykernel not found in venv"
			vim.wait(8000, function()
				return has(needle)
			end, 100)
			vim.wait(500)
			check(has(needle), name .. ": notification missing: " .. needle)
			check(not has("No venv for"), name .. ": .venv exists, 'No venv' would be wrong")
		end
		dump_captured()
	end
end

vim.fn.writefile({ tostring(fails) }, "/sandbox/results/scenarios.status")
if fails > 0 then
	print(string.format("=== scenario suite: %d FAILURES ===", fails))
	pcall(vim.cmd, "cquit 1")
else
	print("=== scenario suite: all checks passed ===")
end
