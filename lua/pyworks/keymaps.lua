-- Keymaps for pyworks.nvim
-- Cell execution with Molten integration for Python:
-- 1. Python files (.py) with python3 kernel
-- 2. Python notebooks (.ipynb) with python3 kernel
-- Uses Molten + image.nvim for execution and display

local M = {}

local detector = require("pyworks.core.detector")
local error_handler = require("pyworks.core.error_handler")
local ui = require("pyworks.ui")

local function get_cell_engine()
	return require("pyworks.core.cell_engine")
end

-- Return the Vim-regex cell marker pattern from the configured cell_marker.
-- Replaces all hardcoded cell_pattern() references so custom markers (e.g.
-- "# COMMAND ----------" for Databricks) work for execution and navigation.
local function cell_pattern()
	return get_cell_engine().vim_search_pattern()
end

local BUFFER_SETTLE_DELAY_MS = 100
local POLL_INTERVAL_MS = 150 -- How often to check for cell completion
local CELL_TIMEOUT_MS = 30000 -- Maximum wait time per cell (30 seconds)

-- Run-all in-progress flags, keyed by bufnr. A second <leader>jR while a
-- run is active would start an interleaved sequence that double-executes
-- cells against the shared Out[N] completion counter.
local run_all_in_progress = {}

-- Debug log file (set vim.g.pyworks_debug_file = "/tmp/pyworks.log" to enable)
local function debug_log(msg)
	local log_file = vim.g.pyworks_debug_file
	if not log_file then
		return
	end
	local f = io.open(log_file, "a")
	if f then
		f:write(string.format("[%s] %s\n", os.date("%H:%M:%S"), msg))
		f:close()
	end
end

-- Cache for Molten namespace ID (invalidated on buffer change to handle namespace recreation)
--
-- IMPORTANT: Molten creates multiple namespaces with similar names:
--   - "molten-extmarks": Contains cell output markers (Out[N]: ✓ Done) - THIS IS WHAT WE NEED
--   - "molten-highlights": Contains syntax highlighting for code cells
--   - potentially others
--
-- We MUST use exact string match "molten-extmarks", NOT a pattern like "^molten".
-- Pattern matching is dangerous because Lua table iteration order is non-deterministic,
-- so "^molten" might match "molten-highlights" first, causing completion detection to fail
-- since that namespace doesn't contain the Out[N] markers we're looking for.
--
-- Bug history: Prior to commit 91adb5c, we used pattern `name:match("^molten")` which
-- sometimes matched the wrong namespace, causing 30-second timeouts on every cell.
local molten_ns_cache = nil

-- Invalidate namespace cache (called on buffer switch to handle Molten restart)
local function invalidate_molten_ns_cache()
	molten_ns_cache = nil
end

-- Set up cache invalidation on buffer changes
-- IMPORTANT: Skip invalidation during notebook reload to prevent contributing
-- to the autocmd cascade that causes E132 maxfuncdepth errors with MoltenTick
local ns_cache_augroup = vim.api.nvim_create_augroup("PyworksMoltenNsCache", { clear = true })
vim.api.nvim_create_autocmd("BufEnter", {
	group = ns_cache_augroup,
	pattern = { "*.py", "*.ipynb" },
	callback = function()
		-- Skip cache invalidation during notebook reload operations
		-- This prevents adding to the call stack during reload cascades
		local ok, guard = pcall(require, "pyworks.core.recursion_guard")
		if ok and guard.is_reloading() then
			if vim.g.pyworks_debug then
				debug_log("BufEnter: skipping cache invalidation (reload in progress)")
			end
			return
		end
		invalidate_molten_ns_cache()
	end,
	desc = "Pyworks: Invalidate Molten namespace cache on buffer switch",
})

-- Concatenate virtual text parts into a single string.
-- Called every 150ms during cell-completion polling; uses table.concat
-- to avoid O(n^2) string-builder allocations on large extmark groups.
local function concat_virt_text(virt_text)
	local parts = {}
	for i, vt in ipairs(virt_text) do
		parts[i] = vt[1] or ""
	end
	return table.concat(parts)
end

-- Get Molten extmarks namespace ID (cached scalar)
--
-- CRITICAL: Must match "molten-extmarks" EXACTLY - this is where Out[N] markers appear.
-- DO NOT use pattern matching like name:match("^molten") - see comment above molten_ns_cache.
--
-- The "cache" is honest now: nvim_get_namespaces() is one API call either
-- way, so the cached path just avoids re-assigning; staleness is detected
-- by verifying the cached ID maps back to "molten-extmarks" in the SAME
-- table (Molten restarts can recreate namespaces with new IDs).
--
-- @return number|nil The namespace ID, or nil if molten-extmarks not found
local function get_molten_namespace()
	local namespaces = vim.api.nvim_get_namespaces()

	local id = namespaces["molten-extmarks"]
	if id == nil then
		debug_log("get_molten_namespace: NOT FOUND (molten-extmarks)")
		molten_ns_cache = nil
		return nil
	end
	molten_ns_cache = id
	debug_log(string.format("get_molten_namespace: id=%d", id))
	return id
end

-- Debug: dump all extmarks with virtual text/lines to see actual Molten output format
local function debug_dump_extmarks(bufnr)
	local namespaces = vim.api.nvim_get_namespaces()
	local found_any = false

	for ns_name, ns_id in pairs(namespaces) do
		if type(ns_name) == "string" then
			local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
			for _, mark in ipairs(marks) do
				local details = mark[4]
				-- Check virt_text (text at end of line)
				if details and details.virt_text then
					found_any = true
					local full_text = concat_virt_text(details.virt_text)
					vim.notify(
						string.format("[DEBUG] ns=%s line=%d virt_text='%s'", ns_name, mark[2] + 1, full_text),
						vim.log.levels.INFO
					)
				end
				-- Check virt_lines (entire lines below the actual line)
				if details and details.virt_lines then
					found_any = true
					for line_idx, virt_line in ipairs(details.virt_lines) do
						local line_text = concat_virt_text(virt_line)
						vim.notify(
							string.format(
								"[DEBUG] ns=%s line=%d virt_lines[%d]='%s'",
								ns_name,
								mark[2] + 1,
								line_idx,
								line_text
							),
							vim.log.levels.INFO
						)
					end
				end
			end
		end
	end

	if not found_any then
		vim.notify("[DEBUG] No extmarks with virtual text/lines found in any namespace", vim.log.levels.INFO)
	end
end

-- Check if text contains completed output pattern and extract the number
-- Returns the Out[N] number if completed, nil otherwise
local function extract_completed_output_num(text)
	local num = text:match("Out%[(%d+)%]")
	if num and (text:match("✓") or text:match("Done")) then
		return tonumber(num)
	end
	return nil
end

-- Find the highest completed Out[N] number in the buffer's virtual text/lines
-- Looks for "Out[N]: ✓ Done" pattern which indicates cell execution completed
-- Optimized: Only checks Molten namespace (not LSP diagnostics etc.)
-- Returns the highest completed number found, or 0 if none
local function get_highest_completed_output(bufnr)
	local highest = 0

	-- Only check Molten namespace for performance (skip LSP diagnostics etc.)
	local ns_id = get_molten_namespace()
	if not ns_id then
		return 0
	end

	local marks = vim.api.nvim_buf_get_extmarks(bufnr, ns_id, 0, -1, { details = true })
	for _, mark in ipairs(marks) do
		local details = mark[4]

		-- Check virt_text (text at end of line)
		if details and details.virt_text then
			local full_text = concat_virt_text(details.virt_text)
			local n = extract_completed_output_num(full_text)
			if n and n > highest then
				highest = n
			end
		end

		-- Check virt_lines (entire virtual lines below the actual line)
		-- This is what Molten uses for output display
		if details and details.virt_lines then
			for _, virt_line in ipairs(details.virt_lines) do
				local line_text = concat_virt_text(virt_line)
				local n = extract_completed_output_num(line_text)
				if n and n > highest then
					highest = n
				end
			end
		end
	end

	return highest
end

-- Wait for cell execution to complete by monitoring Out[N] ✓ Done pattern
-- Calls callback(success) when a new completed output appears or timeout
local function wait_for_cell_completion(bufnr, callback)
	local start_time = vim.uv.now()
	local initial_completed = get_highest_completed_output(bufnr)

	debug_log(string.format("wait_for_cell_completion: START initial_completed=%d", initial_completed))

	-- Debug: log initial state and dump extmarks
	if vim.g.pyworks_debug then
		vim.notify(
			string.format("[DEBUG] wait_for_cell_completion: initial_completed=%d", initial_completed),
			vim.log.levels.DEBUG
		)
		debug_dump_extmarks(bufnr)
	end

	local timer = vim.uv.new_timer()

	-- Helper to safely close timer (prevents double-close errors from race conditions)
	-- Uses libuv's is_closing() API per official Neovim documentation
	local function close_timer()
		if timer:is_closing() then
			return
		end
		timer:stop()
		timer:close()
	end

	timer:start(
		POLL_INTERVAL_MS,
		POLL_INTERVAL_MS,
		vim.schedule_wrap(function()
			-- Skip if timer already closing (callback was scheduled before close)
			if timer:is_closing() then
				return
			end

			-- Check timeout
			if vim.uv.now() - start_time > CELL_TIMEOUT_MS then
				close_timer()
				debug_log("wait_for_cell_completion: TIMEOUT")
				-- Debug: dump extmarks on timeout to see what we missed
				if vim.g.pyworks_debug then
					vim.notify("[DEBUG] Timeout reached, dumping extmarks:", vim.log.levels.DEBUG)
					debug_dump_extmarks(bufnr)
				end
				callback(false, "timeout")
				return
			end

			-- Check if buffer is still valid
			if not vim.api.nvim_buf_is_valid(bufnr) then
				close_timer()
				debug_log("wait_for_cell_completion: BUFFER_INVALID")
				callback(false, "buffer_invalid")
				return
			end

			-- Check if a new Out[N] ✓ Done appeared (completion indicator)
			local current_completed = get_highest_completed_output(bufnr)
			debug_log(string.format("POLL: initial=%d current=%d", initial_completed, current_completed))
			if current_completed > initial_completed then
				close_timer()
				debug_log(string.format("wait_for_cell_completion: SUCCESS Out[%d]", current_completed))
				if vim.g.pyworks_debug then
					vim.notify(
						string.format("[DEBUG] Cell completed! Out[%d] detected", current_completed),
						vim.log.levels.DEBUG
					)
				end
				callback(true)
				return
			end
		end)
	)
end

-- Thin delegate kept only for the M._is_markdown_cell test hook: the
-- keymaps-local cursor-search copy is gone (F3); the canonical check is
-- cell_engine.is_markdown_cell -> core.cell_model.
local function is_markdown_cell()
	return get_cell_engine().is_markdown_cell()
end

-- Suppress Molten events during navigation (workaround for Molten extmark bug)
-- Uses API calls instead of normal! commands to work from any mode (including terminal)
local function with_suppressed_events(fn)
	local saved = vim.o.eventignore
	vim.o.eventignore = "CursorMoved,CursorMovedI,WinScrolled"
	local ok, err = pcall(fn)
	vim.o.eventignore = saved
	if not ok then
		error(err)
	end
end

-- Set up keymaps for a buffer
function M.setup_buffer_keymaps()
	local opts = { buffer = true, silent = true }

	-- Check if Molten is available (it's a remote plugin, not a Lua module)
	local has_molten = vim.fn.exists(":MoltenInit") == 2

	if has_molten then
		-- Molten-specific keymaps

		-- ============================================================================
		-- CELL EXECUTION
		-- ============================================================================

		-- Run current line (auto-initializes kernel if needed)
		vim.keymap.set("n", "<leader>jl", function()
			local bufnr = vim.api.nvim_get_current_buf()
			if not vim.b[bufnr].molten_initialized then
				local ft = vim.bo.filetype
				local filepath = vim.api.nvim_buf_get_name(bufnr)
				-- Kernel resolution is async (no UI-thread blocking)
				detector.get_kernel_for_language(ft, filepath, function(kernel)
					-- Buffer may have changed while the lookup ran
					if not vim.api.nvim_buf_is_valid(bufnr) then
						return
					end
					if not (kernel and kernel:match("^[%w%-_%.]+$")) then
						vim.notify("No suitable kernel found. Run :PyworksSetup to configure.", vim.log.levels.WARN)
						return
					end

					vim.notify("Initializing " .. kernel .. " kernel...", vim.log.levels.INFO)
					local ok =
						error_handler.protected_call(vim.cmd, "Failed to initialize kernel", "MoltenInit " .. kernel)
					if not ok then
						vim.notify("Failed to initialize kernel: " .. kernel, vim.log.levels.WARN)
						return
					end
					vim.b[bufnr].molten_initialized = true

					-- Defer execution to allow kernel initialization to complete
					vim.defer_fn(function()
						-- Don't evaluate into a buffer the user has moved to
						if vim.api.nvim_get_current_buf() ~= bufnr then
							return
						end
						error_handler.protected_call(vim.cmd, "Failed to evaluate line", "MoltenEvaluateLine")
						local cursor = vim.api.nvim_win_get_cursor(0)
						local next_line = cursor[1] + 1
						local last_line = vim.api.nvim_buf_line_count(bufnr)
						if next_line <= last_line then
							vim.api.nvim_win_set_cursor(0, { next_line, cursor[2] })
						end
					end, BUFFER_SETTLE_DELAY_MS)
				end)
				return
			end

			pcall(vim.cmd, "MoltenEvaluateLine")

			-- Auto-advance to next line
			local cursor = vim.api.nvim_win_get_cursor(0)
			local next_line = cursor[1] + 1
			local last_line = vim.api.nvim_buf_line_count(bufnr)
			if next_line <= last_line then
				vim.api.nvim_win_set_cursor(0, { next_line, cursor[2] })
			end
		end, vim.tbl_extend("force", opts, { desc = "Molten: Run current line" }))

		-- Run visual selection
		vim.keymap.set(
			"v",
			"<leader>jr",
			":<C-u>MoltenEvaluateVisual<CR>",
			vim.tbl_extend("force", opts, { desc = "Run selection" })
		)

		-- Also support visual block mode
		vim.keymap.set(
			"x",
			"<leader>jr",
			":<C-u>MoltenEvaluateVisual<CR>",
			vim.tbl_extend("force", opts, { desc = "Run selection" })
		)

		-- Run current cell and move to next (classic Jupyter Shift+Enter behavior)
		vim.keymap.set("n", "<leader>jj", function()
			get_cell_engine().run_cell({ advance = true })
		end, vim.tbl_extend("force", opts, { desc = "Run cell and move to next" }))

		vim.keymap.set("n", "<leader>jk", function()
			get_cell_engine().run_cell()
		end, vim.tbl_extend("force", opts, { desc = "Run cell (stay in place)" }))

		-- ============================================================================
		-- RUN ALL CELLS (<leader>jR)
		-- ============================================================================
		-- Executes all marker cells in the buffer sequentially, waiting for each
		-- to complete.
		--
		-- HOW IT WORKS (F3 — cell-model driven):
		-- 1. Snapshot the canonical cells from core/cell_model (markers only;
		--    the preamble never runs, matching historical behavior).
		-- 2. For each cell in order:
		--    a. markdown cells are skipped by TYPE, empty cells by range;
		--    b. code cells dispatch via MoltenEvaluateRange over the cell's
		--       exact content range [start_line, end_line];
		--    c. completion is polled from Molten's extmarks for
		--       "Out[N]: ✓ Done" (see COMPLETION DETECTION below);
		--    d. on completion (or 30s timeout), proceed to the next cell.
		-- 3. When all cells are done, position the cursor at the last cell.
		--
		-- Why the model: the pre-F3 implementation navigated with
		-- vim.fn.search(pattern, "bnW")/cursor tricks; with the cursor ON a
		-- marker line the missing "c" flag returned the PREVIOUS marker, so
		-- ranges shifted by one cell — adjacent cells double-executed and the
		-- [markdown] skip checked the wrong cell (known bug in
		-- docs/UX_MODEL_A_REFACTOR.md; the ranges now come from the model and
		-- the failure mode is structurally gone).
		--
		-- COMPLETION DETECTION:
		-- - Molten displays output as virtual text in the "molten-extmarks" namespace
		-- - When a cell completes, it shows "Out[N]: ✓ Done (X.Xs)" pattern
		-- - We poll every 150ms checking if a new Out[N] appeared
		-- - Example: Before cell 1 runs, highest=0. After completion, highest=1.
		--
		-- EVENT SUPPRESSION:
		-- - Cursor movements trigger CursorMoved events that can confuse Molten
		-- - We suppress these events during navigation using vim.o.eventignore
		-- - Uses API calls (nvim_win_set_cursor) instead of normal! commands
		--   to work from any mode including terminal mode
		-- ============================================================================
		vim.keymap.set("n", "<leader>jR", function()
			local bufnr = vim.api.nvim_get_current_buf()
			if not vim.b[bufnr].molten_initialized then
				vim.notify("No kernel initialized. Press <leader>jl to auto-initialize.", vim.log.levels.WARN)
				return
			end

			-- In-progress guard: one run-all at a time per buffer
			if run_all_in_progress[bufnr] then
				vim.notify("Run all already in progress in this buffer", vim.log.levels.WARN)
				return
			end

			-- Step 1: canonical cells from the model (marker cells only).
			-- Cell line numbers are a snapshot; every iteration revalidates
			-- against the live buffer before dispatching (staleness below).
			local cells = {}
			for _, cell in ipairs(require("pyworks.core.cell_model").markers(bufnr)) do
				table.insert(cells, cell)
			end

			if #cells == 0 then
				vim.notify("No cells found in buffer", vim.log.levels.WARN)
				return
			end

			vim.notify(string.format("Running %d cells...", #cells), vim.log.levels.INFO)
			run_all_in_progress[bufnr] = true

			-- Abort helper: drop the in-progress flag so a future run is possible
			local function abort_run(reason)
				run_all_in_progress[bufnr] = nil
				vim.notify("Run all aborted: " .. reason, vim.log.levels.WARN)
			end

			-- Step 2: recursive function to execute cells one by one
			-- Each call handles one cell, then schedules the next via vim.defer_fn
			local function run_next_cell(i)
				local function schedule_next()
					vim.defer_fn(function()
						run_next_cell(i + 1)
					end, BUFFER_SETTLE_DELAY_MS)
				end

				-- Base case: all cells handled — park the cursor at the last one
				if i > #cells then
					run_all_in_progress[bufnr] = nil
					with_suppressed_events(function()
						ui.enter_cell(cells[#cells].marker_line, { insert_mode = false, append = false })
					end)
					vim.notify("All cells executed", vim.log.levels.INFO)
					return
				end

				local cell = cells[i]

				-- Revalidate before each dispatch. Each cell can wait up to 30s,
				-- so mid-run edits/buffer switches are likely; executing a stale
				-- snapshot range would run the WRONG lines.
				if not vim.api.nvim_buf_is_valid(bufnr) then
					run_all_in_progress[bufnr] = nil
					return
				end
				if vim.api.nvim_get_current_buf() ~= bufnr then
					abort_run("buffer switched during run")
					return
				end
				local fresh_cell = require("pyworks.core.cell_model").cell_at(bufnr, cell.marker_line)
				if
					not fresh_cell
					or fresh_cell.marker_line ~= cell.marker_line
					or fresh_cell.marker_text ~= cell.marker_text
				then
					abort_run("buffer edited during run (cell layout changed)")
					return
				end
				cell = fresh_cell

				-- Skip markdown (no executable code) and empty cells (by range)
				if cell.type == "markdown" or cell.start_line > cell.end_line then
					schedule_next()
					return
				end

				-- Mark executed only for cells that actually dispatch
				ui.mark_cell_executed(cell.index)

				-- Execute the cell over its exact model range
				local ok = pcall(vim.fn.MoltenEvaluateRange, cell.start_line, cell.end_line)
				if not ok then
					vim.fn.setpos("'<", { 0, cell.start_line, 1, 0 })
					vim.fn.setpos("'>", { 0, cell.end_line, vim.fn.col({ cell.end_line, "$" }) - 1, 0 })
					pcall(vim.cmd, "'<,'>MoltenEvaluateVisual")
				end

				-- Move cursor to next cell for visual feedback (output appears above)
				local next_cell = cells[i + 1]
				if next_cell then
					with_suppressed_events(function()
						ui.enter_cell(next_cell.marker_line, { insert_mode = false, append = false })
					end)
				end

				-- Wait for completion by polling Molten's extmarks
				-- Looks for "Out[N]: ✓ Done" pattern to detect when cell finishes
				wait_for_cell_completion(bufnr, function(success, reason)
					if not success and reason == "timeout" then
						vim.notify(
							string.format("Cell %d timed out after 30s, continuing...", cell.index),
							vim.log.levels.WARN
						)
					end
					-- Small delay to let output render, then continue to next cell
					schedule_next()
				end)
			end

			-- Start execution from the first marker cell
			run_next_cell(1)
		end, vim.tbl_extend("force", opts, { desc = "Run all cells" }))

		-- ============================================================================
		-- CELL SELECTION & NAVIGATION
		-- ============================================================================

		-- Visual select current cell
		vim.keymap.set("n", "<leader>jv", function()
			if vim.bo.filetype == "python" and not vim.g.python3_host_prog then
				vim.notify("Python host not configured. Run :PyworksSetup first", vim.log.levels.WARN)
				return
			end

			local has_cells = get_cell_engine().count_cells(0) > 0
			local last_line = vim.api.nvim_buf_line_count(0)

			local start_line, end_line
			if has_cells then
				start_line, end_line = get_cell_engine().find_cell_boundaries()
				if not start_line then
					vim.notify("Empty cell", vim.log.levels.INFO)
					return
				end
			else
				start_line, end_line = 1, last_line
				vim.notify("No cell markers found, selected entire file", vim.log.levels.INFO)
			end

			vim.api.nvim_win_set_cursor(0, { start_line, 0 })
			vim.cmd.normal({ "V", bang = true })
			vim.api.nvim_win_set_cursor(0, { end_line, 0 })
		end, vim.tbl_extend("force", opts, { desc = "Visual select current cell" }))

		-- Go to cell N
		vim.keymap.set("n", "<leader>jg", function()
			vim.ui.input({ prompt = "Go to cell number: " }, function(input)
				if not input or input == "" then
					return
				end
				local cell_num = tonumber(input)
				if not cell_num or cell_num < 1 then
					vim.notify("Invalid cell number", vim.log.levels.ERROR)
					return
				end

				local positions = get_cell_engine().get_cell_positions(0)
				if #positions == 0 then
					vim.notify("No cells found in this file", vim.log.levels.WARN)
					return
				end
				if cell_num > #positions then
					vim.notify(
						string.format("Cell %d not found (only %d cells exist)", cell_num, #positions),
						vim.log.levels.WARN
					)
					return
				end

				local marker_line = positions[cell_num]
				local target_line = math.min(marker_line + 1, vim.api.nvim_buf_line_count(0))
				vim.api.nvim_win_set_cursor(0, { target_line, 0 })
				vim.notify("Jumped to cell " .. cell_num, vim.log.levels.INFO)
			end)
		end, vim.tbl_extend("force", opts, { desc = "Go to cell N" }))

		-- ============================================================================
		-- OUTPUT MANAGEMENT
		-- ============================================================================

		vim.keymap.set("n", "<leader>jd", function()
			local cell_num = ui.get_current_cell_number()
			if cell_num == 0 then
				vim.notify("Not in a cell", vim.log.levels.INFO)
				return
			end
			local ok = pcall(vim.cmd, "MoltenDelete")
			if ok then
				ui.mark_cell_cleared(cell_num)
			else
				vim.notify("No output to delete", vim.log.levels.INFO)
			end
		end, vim.tbl_extend("force", opts, { desc = "Clear cell output" }))

		-- ============================================================================
		-- CELL CREATION
		-- ============================================================================

		vim.keymap.set("n", "<leader>ja", function()
			get_cell_engine().insert_cell_above()
		end, vim.tbl_extend("force", opts, { desc = "Insert code cell above" }))

		vim.keymap.set("n", "<leader>jb", function()
			get_cell_engine().insert_cell_below()
		end, vim.tbl_extend("force", opts, { desc = "Insert code cell below" }))

		vim.keymap.set("n", "<leader>jma", function()
			get_cell_engine().insert_markdown_above()
		end, vim.tbl_extend("force", opts, { desc = "Insert markdown cell above" }))

		vim.keymap.set("n", "<leader>jmb", function()
			get_cell_engine().insert_markdown_below()
		end, vim.tbl_extend("force", opts, { desc = "Insert markdown cell below" }))

		-- ============================================================================
		-- CELL OPERATIONS
		-- ============================================================================

		-- Toggle cell type (code ↔ markdown)
		vim.keymap.set("n", "<leader>jt", function()
			if not get_cell_engine().toggle_cell_type() then
				vim.notify("Not in a cell", vim.log.levels.WARN)
			end
		end, vim.tbl_extend("force", opts, { desc = "Toggle cell type" }))

		vim.keymap.set("n", "<leader>jJ", function()
			if not get_cell_engine().merge_cell_below() then
				vim.notify("No cell below to merge", vim.log.levels.WARN)
			else
				vim.notify("Merged with cell below", vim.log.levels.INFO)
			end
		end, vim.tbl_extend("force", opts, { desc = "Merge with cell below" }))

		vim.keymap.set("n", "<leader>js", function()
			get_cell_engine().split_cell()
			vim.notify("Cell split", vim.log.levels.INFO)
		end, vim.tbl_extend("force", opts, { desc = "Split cell at cursor" }))

		-- ============================================================================
		-- CELL FOLDING & UI
		-- ============================================================================

		vim.keymap.set("n", "<leader>jf", function()
			ui.toggle_cell_folding()
		end, vim.tbl_extend("force", opts, { desc = "Toggle cell folding" }))

		vim.keymap.set("n", "<leader>jc", function()
			ui.collapse_cell()
		end, vim.tbl_extend("force", opts, { desc = "Collapse current cell" }))

		vim.keymap.set("n", "<leader>jC", function()
			ui.collapse_all_cells()
		end, vim.tbl_extend("force", opts, { desc = "Collapse all cells" }))

		vim.keymap.set("n", "<leader>je", function()
			ui.expand_cell()
		end, vim.tbl_extend("force", opts, { desc = "Expand current cell" }))

		vim.keymap.set("n", "<leader>jE", function()
			ui.expand_all_cells()
		end, vim.tbl_extend("force", opts, { desc = "Expand all cells" }))

		vim.keymap.set("n", "<leader>jn", function()
			ui.number_cells()
			vim.notify("Cell numbers refreshed", vim.log.levels.INFO)
		end, vim.tbl_extend("force", opts, { desc = "Refresh cell numbers" }))
	else
		-- Fallback keymaps when Molten is not available (select text for manual copying)

		vim.keymap.set("n", "<leader>jv", function()
			-- Use pcall to handle E486 (pattern not found) gracefully
			local ok = pcall(function()
				local cp = cell_pattern():gsub("/", "\\/")
				vim.cmd("normal! ?" .. cp .. "\\|^```\\|^```{<CR>")
				vim.cmd("normal! V")
				vim.cmd("normal! /" .. cp .. "\\|^```\\|^```{<CR>")
				vim.cmd("normal! k")
			end)
			if ok then
				vim.notify("Molten not available. Cell selected for manual copy.", vim.log.levels.WARN)
			else
				vim.notify("No cell markers found", vim.log.levels.INFO)
			end
		end, vim.tbl_extend("force", opts, { desc = "Select current cell (Molten not available)" }))

		vim.keymap.set("v", "<leader>jr", function()
			vim.notify("Molten not available. Copy selection to run elsewhere.", vim.log.levels.WARN)
		end, vim.tbl_extend("force", opts, { desc = "Run selection (Molten not available)" }))

		vim.keymap.set("n", "<leader>jl", function()
			vim.notify("Molten not available. Use :MoltenInit to initialize.", vim.log.levels.WARN)
		end, vim.tbl_extend("force", opts, { desc = "Run current line (Molten not available)" }))
	end

	vim.keymap.set("n", "<leader>j]", function()
		if not get_cell_engine().next_cell() then
			vim.notify("No more cells", vim.log.levels.INFO)
		end
	end, vim.tbl_extend("force", opts, { desc = "Next cell" }))

	vim.keymap.set("n", "<leader>j[", function()
		if not get_cell_engine().prev_cell() then
			vim.notify("No previous cell", vim.log.levels.INFO)
		end
	end, vim.tbl_extend("force", opts, { desc = "Previous cell" }))

	-- Format markdown cell content (independent of Molten; notebooks.md_formatter).
	-- Primary: <leader>jm (keeps <leader>jf unshadowed so fold toggling is
	-- instant); <leader>jfm kept as an alias for muscle memory.
	local format_md = function()
		require("pyworks.commands.format_cell").format_current_cell()
	end
	vim.keymap.set("n", "<leader>jm", format_md, vim.tbl_extend("force", opts, { desc = "Format markdown cell" }))
	vim.keymap.set("n", "<leader>jfm", format_md, vim.tbl_extend("force", opts, { desc = "Format markdown cell" }))

	-- Debug command: dump all extmarks to see Molten's output format.
	-- Previously registered at module load (side-effecting require).
	vim.api.nvim_create_user_command("PyworksDebugExtmarks", function()
		local bufnr = vim.api.nvim_get_current_buf()
		vim.notify("[DEBUG] Dumping all extmarks with virtual text:", vim.log.levels.INFO)
		debug_dump_extmarks(bufnr)
		local highest = get_highest_completed_output(bufnr)
		vim.notify(string.format("[DEBUG] Highest completed output: Out[%d]", highest), vim.log.levels.INFO)
	end, { desc = "Debug: dump all extmarks to see Molten output format" })
end

-- Set up Molten kernel management keymaps
function M.setup_molten_keymaps()
	local opts = { buffer = true, silent = true }
	local has_molten = vim.fn.exists(":MoltenInit") == 2

	if has_molten then
		vim.keymap.set("n", "<leader>mi", function()
			vim.ui.input({ prompt = "Kernel name: " }, function(input)
				if input and input:match("^[%w%-_%.]+$") then
					vim.cmd("MoltenInit " .. input)
				elseif input and input ~= "" then
					vim.notify(
						"Invalid kernel name: only letters, numbers, hyphens, underscores, dots allowed",
						vim.log.levels.WARN
					)
				end
			end)
		end, vim.tbl_extend("force", opts, { desc = "Initialize kernel" }))

		vim.keymap.set("n", "<leader>mr", function()
			local ok = pcall(vim.cmd, "MoltenRestart")
			if not ok then
				vim.notify("No kernel to restart. Initialize with <leader>mi first.", vim.log.levels.WARN)
			end
		end, vim.tbl_extend("force", opts, { desc = "Restart kernel" }))

		vim.keymap.set("n", "<leader>mx", function()
			local ok = pcall(vim.cmd, "MoltenInterrupt")
			if not ok then
				vim.notify("No kernel to interrupt. Initialize with <leader>mi first.", vim.log.levels.WARN)
			end
		end, vim.tbl_extend("force", opts, { desc = "Interrupt execution" }))

		vim.keymap.set("n", "<leader>mI", function()
			local ok = pcall(vim.cmd, "MoltenInfo")
			if not ok then
				vim.notify("No kernel info available. Initialize with <leader>mi first.", vim.log.levels.WARN)
			end
		end, vim.tbl_extend("force", opts, { desc = "Show kernel info" }))
	end
end

-- Export internal functions for testing
M._get_highest_completed_output = get_highest_completed_output
M._is_markdown_cell = is_markdown_cell
M._wait_for_cell_completion = wait_for_cell_completion
M._debug_dump_extmarks = debug_dump_extmarks
M._get_molten_namespace = get_molten_namespace
M._invalidate_molten_ns_cache = invalidate_molten_ns_cache

return M
