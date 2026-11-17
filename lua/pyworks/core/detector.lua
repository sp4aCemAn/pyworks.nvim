-- Core file type detection and routing system for pyworks.nvim
-- This module is the entry point for all file handling

local M = {}

local cache = require("pyworks.core.cache")
local notifications = require("pyworks.core.notifications")
local state = require("pyworks.core.state")
local utils = require("pyworks.utils")

-- Timeout constants (in milliseconds)
local KERNEL_LIST_TIMEOUT_MS = 10000 -- 10 seconds for kernel listing
local KERNEL_CREATE_TIMEOUT_MS = 30000 -- 30 seconds for kernel creation

-- Language detection for notebooks (pyworks only supports Python)
local function detect_notebook_language(_filepath)
	return "python"
end

-- Main file handler
function M.on_file_open(filepath)
	-- Validate and ensure absolute filepath
	if not filepath or filepath == "" then
		return
	end

	-- Ensure absolute path
	if not filepath:match("^/") then
		filepath = vim.fn.fnamemodify(filepath, ":p")
	end

	-- Skip if already processing
	local processing_key = state.KEYS.PROCESSING .. filepath
	if state.get(processing_key) then
		return
	end

	state.set(processing_key, true)

	-- Helper to ensure processing flag is always cleared (finally pattern)
	local function clear_processing_flag()
		vim.defer_fn(function()
			state.set(processing_key, nil)
		end, 100)
	end

	-- Detect file type
	local ext = vim.fn.fnamemodify(filepath, ":e")
	local ft = vim.bo.filetype

	-- Show that detection is happening
	if notifications.get_config().debug_mode then
		notifications.notify(
			string.format("[Detector] Processing %s (ext: %s, ft: %s)", filepath, ext, ft),
			vim.log.levels.DEBUG
		)
	end

	-- Route to appropriate handler (Python only) with error protection
	local ok, err = pcall(function()
		if ext == "ipynb" then
			M.handle_notebook(filepath)
		elseif ext == "py" or ft == "python" then
			M.handle_python(filepath)
		end
	end)

	-- Always clear the processing flag, even if handler failed
	clear_processing_flag()

	-- Log error if handler failed (but don't propagate it)
	if not ok then
		notifications.notify(
			string.format("Error processing %s: %s", vim.fn.fnamemodify(filepath, ":t"), tostring(err)),
			vim.log.levels.ERROR
		)
	end
end

-- Handle notebook files
function M.handle_notebook(filepath)
	-- Step 1: Ensure jupytext is available
	local notebook = require("pyworks.notebook.jupytext")
	if not notebook.ensure_jupytext() then
		-- Get project info for better instructions
		local project_dir, venv_path = utils.get_project_paths(filepath)
		local project_type = utils.detect_project_type(project_dir)
		local project_rel = vim.fn.fnamemodify(project_dir, ":~:.")

		notifications.notify(
			string.format("Cannot open %s notebook: jupytext not found", project_type),
			vim.log.levels.ERROR
		)
		notifications.notify(
			string.format("Run :PyworksSetup to create venv at: %s/.venv", project_rel),
			vim.log.levels.INFO
		)
		return
	end

	-- Handle as Python notebook (pyworks only supports Python)
	M.handle_python_notebook(filepath)
end

-- Fetch + parse the kernelspec list once (async; UI never blocks).
-- Cached under "kernel_list" (60s TTL). Callback receives
--   { by_language = { <lang> = <kernel_name> },
--     python_specs = { { name = ..., python = <argv[1]> }, ... } }
-- or nil when jupyter is unavailable/failed.
local function fetch_kernelspecs(callback)
	local cached = cache.get("kernel_list")
	if cached then
		callback(cached)
		return
	end

	utils.async_system_call({ "jupyter", "kernelspec", "list", "--json" }, function(success, stdout)
		if not success then
			callback(nil)
			return
		end
		local ok, data = pcall(vim.json.decode, stdout)
		if not ok or type(data) ~= "table" or not data.kernelspecs then
			callback(nil)
			return
		end

		local parsed = { by_language = {}, python_specs = {} }
		for name, spec in pairs(data.kernelspecs) do
			local spec_tbl = spec.spec
			if spec_tbl and spec_tbl.language then
				local lang = spec_tbl.language:lower()
				if not parsed.by_language[lang] then
					parsed.by_language[lang] = name
				end
				if lang == "python" and spec_tbl.argv and spec_tbl.argv[1] then
					table.insert(parsed.python_specs, { name = name, python = spec_tbl.argv[1] })
				end
			end
		end
		cache.set("kernel_list", parsed)
		callback(parsed)
	end, { timeout = KERNEL_LIST_TIMEOUT_MS })
end

-- Match a kernel whose python belongs to the project's venv.
-- The prefix requires the "/" boundary: "/proj/.venv2" must NOT match
-- a project whose venv is "/proj/.venv".
local function match_kernel_in_specs(python_specs, venv_path, python_path)
	local venv_prefix = venv_path .. "/"
	for _, entry in ipairs(python_specs) do
		local kernel_python = entry.python

		if notifications.get_config().debug_mode then
			notifications.notify(string.format("Kernel '%s' uses: %s", entry.name, kernel_python), vim.log.levels.DEBUG)
		end

		local is_exact_match = (kernel_python == python_path)
		local is_venv_match = kernel_python:sub(1, #venv_prefix) == venv_prefix
		if is_exact_match or is_venv_match then
			notifications.notify(string.format("Found kernel '%s'", entry.name), vim.log.levels.INFO)
			return entry.name
		elseif notifications.get_config().debug_mode then
			notifications.notify(
				string.format("Kernel '%s' uses %s, not %s", entry.name, kernel_python, python_path),
				vim.log.levels.DEBUG
			)
		end
	end
	return nil
end

-- Find a working Python executable in the venv. nil => the venv directory
-- exists but contains no interpreter (broken/incomplete). Do NOT pretend a
-- python exists: the caller reports the failure instead of feeding a
-- phantom path into kernel matching/creation.
local function find_python_in_venv(venv_path)
	local candidates = {
		venv_path .. "/bin/python",
		venv_path .. "/bin/python3",
		venv_path .. "/bin/python3.12",
	}

	for _, python_path in ipairs(candidates) do
		if vim.fn.executable(python_path) == 1 then
			return python_path
		end
	end

	notifications.notify(
		string.format("No Python found in venv: %s. The venv is broken — recreate it with :PyworksSetup", venv_path),
		vim.log.levels.WARN,
		{ action_required = true }
	)
	return nil
end

-- Create a new kernel for the project (async; UI never blocks).
-- Callback receives the kernel name, or nil on any failure.
local function create_kernel_for_project(project_dir, venv_path, python_path, callback)
	local project_name = vim.fn.fnamemodify(project_dir, ":t")
	local parent_name = vim.fn.fnamemodify(vim.fn.fnamemodify(project_dir, ":h"), ":t")

	local kernel_name
	local parent_dir = vim.fn.fnamemodify(project_dir, ":h")
	-- Skip the parent component when it identifies the USER rather than
	-- the project: the home directory itself (any OS), or macOS's "Users".
	-- Kernel names like "james_myproj" (username-dependent) leak across
	-- machines and collide between users.
	if parent_name == "" or parent_name == "/" or parent_dir == vim.fn.expand("~") or parent_name == "Users" then
		kernel_name = project_name:lower():gsub("[^%w_]", "_")
	else
		kernel_name = (parent_name .. "_" .. project_name):lower():gsub("[^%w_]", "_")
	end

	-- Check if ipykernel is installed (async import probe)
	utils.async_system_call({ python_path, "-c", "import ipykernel" }, function(check_success)
		if not check_success then
			-- uv-created venvs have no bin/pip: point the user at a command
			-- that will actually work for their package manager
			local install_hint
			if vim.fn.executable(venv_path .. "/bin/pip") == 1 then
				install_hint = string.format("%s/bin/pip install ipykernel", venv_path)
			elseif vim.fn.executable("uv") == 1 then
				install_hint = string.format("uv pip install --python %s/bin/python ipykernel", venv_path)
			else
				install_hint = string.format("install ipykernel into the virtual environment at %s", venv_path)
			end
			notifications.notify(
				string.format("ipykernel not found in venv. Run: %s", install_hint),
				vim.log.levels.ERROR,
				{ action_required = true }
			)
			callback(nil)
			return
		end

		notifications.notify(
			string.format("Creating kernel '%s' for venv: %s", kernel_name, venv_path),
			vim.log.levels.INFO
		)

		local cmd = {
			python_path,
			"-m",
			"ipykernel",
			"install",
			"--user",
			"--name",
			kernel_name,
			"--display-name",
			"Python (" .. project_name .. ")",
		}

		utils.async_system_call(cmd, function(create_success, output)
			if create_success then
				notifications.notify(
					string.format("Created kernel '%s' -> %s", kernel_name, python_path),
					vim.log.levels.INFO
				)
				cache.invalidate("kernel_list")
				callback(kernel_name)
			else
				notifications.notify(
					string.format("Failed to create kernel: %s", vim.trim(output or "")),
					vim.log.levels.ERROR
				)
				callback(nil)
			end
		end, { timeout = KERNEL_CREATE_TIMEOUT_MS })
	end, { timeout = KERNEL_LIST_TIMEOUT_MS })
end

-- Resolve the kernel for a language (async).
-- Callback receives the kernel name, or nil when none exists/could be created.
local function get_kernel_for_language(language, filepath, callback)
	-- For non-Python or no filepath: generic kernel lookup
	if language:lower() ~= "python" or not filepath then
		fetch_kernelspecs(function(data)
			local lang = language:lower()
			local kernel = data and data.by_language[lang] or nil
			if kernel then
				notifications.notify(string.format("Using %s kernel: %s", language, kernel), vim.log.levels.INFO)
			end
			callback(kernel)
		end)
		return
	end

	-- Python with filepath: match kernel to project's venv
	local project_dir, venv_path = utils.get_project_paths(filepath)

	if notifications.get_config().debug_mode then
		notifications.notify(
			string.format("Kernel selection: File=%s, Project=%s", filepath, project_dir),
			vim.log.levels.DEBUG
		)
	end

	local python_path = find_python_in_venv(venv_path)
	if not python_path then
		callback(nil)
		return
	end

	if notifications.get_config().debug_mode then
		notifications.notify(
			string.format("Looking for kernel matching venv Python: %s", python_path),
			vim.log.levels.DEBUG
		)
	end

	-- Try to find an existing matching kernel
	fetch_kernelspecs(function(data)
		local kernel = data and match_kernel_in_specs(data.python_specs, venv_path, python_path) or nil
		if kernel then
			callback(kernel)
			return
		end

		-- No matching kernel found - create one
		notifications.notify(string.format("No kernel found for %s", project_dir), vim.log.levels.INFO)
		create_kernel_for_project(project_dir, venv_path, python_path, callback)
	end)
end

-- Initialize Molten automatically for the language (async)
local function auto_init_molten(language, filepath)
	-- Check if Molten is available
	if vim.fn.exists(":MoltenInit") ~= 2 then
		notifications.notify("Molten not available - install with :Lazy load molten-nvim", vim.log.levels.WARN)
		return
	end

	-- Skip if we've already tried to initialize for this buffer
	local bufnr = vim.api.nvim_get_current_buf()
	if vim.b[bufnr].molten_init_attempted then
		return
	end
	vim.b[bufnr].molten_init_attempted = true

	-- Show we're attempting initialization
	notifications.notify(string.format("Setting up %s kernel for execution...", language), vim.log.levels.INFO)

	-- Get the actual kernel name for this language and project
	get_kernel_for_language(language, filepath, function(kernel)
		if not kernel then
			-- No kernel found
			vim.b[bufnr].molten_init_attempted = false -- Allow retry
			notifications.notify("Python kernel not found. Run :PyworksSetup to configure.", vim.log.levels.WARN)
			return
		end

		if not kernel:match("^[%w%-_%.]+$") then
			notifications.notify(string.format("Invalid kernel name: %s", kernel), vim.log.levels.ERROR)
			return
		end

		vim.defer_fn(function()
			-- The kernel lookup is async; only init if the user hasn't
			-- moved to a different buffer meanwhile
			if vim.api.nvim_get_current_buf() ~= bufnr then
				vim.b[bufnr].molten_init_attempted = false
				return
			end

			-- Try to initialize the kernel
			local ok, err = pcall(vim.cmd, "MoltenInit " .. kernel)
			if ok then
				vim.b[bufnr].molten_initialized = true

				-- Show clear notification that kernel is ready
				notifications.notify(
					string.format("Molten ready with %s kernel - Use <leader>jl to run code", kernel),
					vim.log.levels.INFO
				)
			else
				-- If initialization failed, try again later or let user do it manually
				vim.b[bufnr].molten_init_attempted = false -- Allow retry
				notifications.notify(
					string.format(
						"Failed to auto-initialize kernel for %s. Press <leader>mi to initialize manually",
						language
					),
					vim.log.levels.WARN
				)
			end
		end, 200) -- Reduced to 200ms - just enough for buffer to settle
	end)
end

-- Python file handler
function M.handle_python(filepath)
	-- Set up Python host for this file's project
	local python = require("pyworks.languages.python")
	python.setup_python_host(filepath)

	-- Show detailed project and venv detection
	local project_dir, venv_path = utils.get_project_paths(filepath)

	-- Get relative paths for cleaner display
	local file_rel = vim.fn.fnamemodify(filepath, ":~:.")
	local project_rel = vim.fn.fnamemodify(project_dir, ":~:.")
	local venv_exists = vim.fn.isdirectory(venv_path) == 1

	-- Detect project type
	local project_type = utils.detect_project_type(project_dir)

	-- Show detection results (deduplication handles repeats)
	if venv_exists then
		notifications.notify(
			string.format("%s project: venv at %s/.venv", project_type, project_rel),
			vim.log.levels.INFO
		)
	else
		notifications.notify(
			string.format("%s project: No venv for %s", project_type, file_rel),
			vim.log.levels.WARN,
			{ action_required = true }
		)
		notifications.notify(
			string.format("Run :PyworksSetup to create venv at: %s/.venv", project_rel),
			vim.log.levels.INFO
		)
		-- Don't auto-create on file open, but still set up for manual creation
		-- Store filepath for PyworksSetup command
		vim.b.pyworks_filepath = filepath
		return
	end

	python.handle_file(filepath)
	auto_init_molten("python", filepath)
end

-- Python notebook handler
function M.handle_python_notebook(filepath)
	-- Set up Python host for this file's project
	local python = require("pyworks.languages.python")
	python.setup_python_host(filepath)

	-- Show detailed project and venv detection for notebooks
	local project_dir, venv_path = utils.get_project_paths(filepath)

	-- Get relative paths for cleaner display
	local file_rel = vim.fn.fnamemodify(filepath, ":~:.")
	local project_rel = vim.fn.fnamemodify(project_dir, ":~:.")
	local venv_exists = vim.fn.isdirectory(venv_path) == 1

	-- Detect project type
	local project_type = utils.detect_project_type(project_dir)

	-- Show detection results (first time only, not forced)
	if venv_exists then
		notifications.notify(
			string.format("%s notebook: venv at %s/.venv", project_type, project_rel),
			vim.log.levels.INFO
		)
	else
		notifications.notify(
			string.format("%s notebook: No venv for %s", project_type, file_rel),
			vim.log.levels.WARN,
			{ action_required = true }
		)
		notifications.notify(
			string.format("Run :PyworksSetup to create venv at: %s/.venv", project_rel),
			vim.log.levels.INFO
		)
		-- Don't auto-create for notebooks, let user decide
		return
	end

	python.handle_file(filepath, { is_notebook = true })
	auto_init_molten("python", filepath)
end

-- Re-scan imports on file save
function M.rescan_imports(filepath)
	local ext = vim.fn.fnamemodify(filepath, ":e")
	local ft = vim.bo.filetype

	if ext == "ipynb" or ext == "py" or ft == "python" then
		local packages = require("pyworks.core.packages")
		packages.rescan_for_language(filepath, "python")
	end
end

-- Export kernel detection for use in other modules.
-- ASYNC: get_kernel_for_language(language, filepath, callback) — the
-- callback receives the kernel name or nil; nothing blocks the UI thread.
M.get_kernel_for_language = get_kernel_for_language
-- Test hooks (private-function convention: M._name)
M._match_kernel_in_specs = match_kernel_in_specs
M._find_python_in_venv = find_python_in_venv
M._fetch_kernelspecs = fetch_kernelspecs
-- Export for testing
M.detect_notebook_language = detect_notebook_language

return M
