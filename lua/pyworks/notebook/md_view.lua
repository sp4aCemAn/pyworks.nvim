-- Inline markdown concealment for notebook buffers (Model A, F6)
--
-- Doctrine: the percent script IS the buffer; notebook feel comes from
-- presentation chrome. Canonical jupytext markdown content is commented
-- ("# text"); this module hides exactly that leading "# " (or bare "#" on
-- empty md lines) with a window-local matchadd range over the markdown
-- content lines from the canonical cell model, so md cells read as
-- markdown while the buffer stays valid Python.
--
-- Spike findings baked in (docs/UX_MODEL_A_REFACTOR.md "F6 SPIKE
-- findings"):
--   - only exclusive line atoms exist: region [s,e] -> \%>{s-1}l\%<{e+1}l
--   - one matchadd with "|"-alternated regions renders correctly and is
--     cheap (rebuild measured ~0 ms; debounce is for input smoothness)
--   - cchar-less conceal ({conceal = ""}) fully hides the matched prefix
--   - Molten eol virt_text (Out[N] polling contract) coexists untouched
--   - concealcursor="nvi": the cursor line always shows the real prefix
--     (insert-mode safety); other lines stay clean
--   - folds coexist; md_fold_default closes md cells at open via
--     cell_fold_expr ">2" for markdown markers + foldlevel 1
--
-- Matches are WINDOW-local: rebuilt on BufWinEnter/WinEnter and (debounced)
-- on TextChanged/TextChangedI/BufWritePost, keyed per window id.

local M = {}

local cell_model = require("pyworks.core.cell_model")
local notebook_lsp = require("pyworks.notebook.lsp")
local ui = require("pyworks.ui")

local PRIORITY = 20
local DEBOUNCE_MS = 150

-- winid -> match id; bufnr -> uv timer
local win_matches = {}
local rebuild_timers = {}

-- Lazy require mirrors the get_mode()/get_packages() cycle-break pattern:
-- init.lua -> here -> pyworks (during setup())
local function get_notebooks_config()
	local ok, pyworks = pcall(require, "pyworks")
	if not ok or type(pyworks.get_config) ~= "function" then
		return {}
	end
	local cfg = pyworks.get_config()
	return (cfg and cfg.notebooks) or {}
end

local function conceal_enabled()
	return get_notebooks_config().md_conceal ~= false
end

local function fold_default_enabled()
	return get_notebooks_config().md_fold_default == true
end

-- Vim regex concealing the comment prefix on every markdown content line.
-- nil when the buffer has no non-empty markdown cell.
-- CRITICAL regex fact (F6 spike, verified against a real ext_linegrid
-- render): the line anchor ^ must LEAD each branch — "^#\s\?\%>Nl\%<Ml" —
-- atoms first work only in a single-branch pattern; after a "\|" they turn
-- the second branch's ^ into a literal caret (zero matches), and wrapping
-- branches in "\%(...\)" has the same trap. Regions [s,e] use the
-- exclusive atoms "\%>{s-1}l\%<{e+1}l" (inclusive "\%>=" does not exist).
local function conceal_pattern(bufnr)
	local regions = cell_model.markdown_regions(bufnr)
	if #regions == 0 then
		return nil
	end
	local parts = {}
	for _, r in ipairs(regions) do
		table.insert(parts, "^#\\s\\?\\%>" .. (r.start_line - 1) .. "l\\%<" .. (r.end_line + 1) .. "l")
	end
	return table.concat(parts, "\\|")
end

local function drop_match(winid)
	local id = win_matches[winid]
	if id then
		vim.api.nvim_win_call(winid, function()
			pcall(vim.fn.matchdelete, id)
		end)
		win_matches[winid] = nil
	end
end

local function apply_window(winid)
	if not vim.api.nvim_win_is_valid(winid) then
		return false
	end
	local ok_buf, bufnr = pcall(vim.api.nvim_win_get_buf, winid)
	if not ok_buf or not notebook_lsp.is_notebook_buf(bufnr) then
		drop_match(winid)
		return false
	end

	drop_match(winid)

	if not conceal_enabled() then
		return false
	end

	vim.api.nvim_win_call(winid, function()
		vim.wo.conceallevel = 2
		vim.wo.concealcursor = "nvi"
		if fold_default_enabled() then
			ui.setup_cell_folding()
			vim.wo.foldlevel = 1
		end
		local pattern = conceal_pattern(bufnr)
		if pattern then
			win_matches[winid] = vim.fn.matchadd("Conceal", pattern, PRIORITY, -1, { conceal = "" })
		end
	end)
	return true
end

local function all_windows_for(bufnr)
	local wins = {}
	for _, tab in ipairs(vim.api.nvim_list_tabpages()) do
		for _, win in ipairs(vim.api.nvim_tabpage_list_wins(tab)) do
			if vim.api.nvim_win_get_buf(win) == bufnr then
				table.insert(wins, win)
			end
		end
	end
	return wins
end

-- Re-sync every window showing `bufnr` (default: current) with the model.
function M.refresh(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	bufnr = (not bufnr or bufnr == 0) and vim.api.nvim_get_current_buf() or bufnr
	for _, win in ipairs(all_windows_for(bufnr)) do
		apply_window(win)
	end
end

local function schedule_refresh(bufnr)
	local timer = rebuild_timers[bufnr]
	if not timer then
		timer = vim.uv.new_timer()
		rebuild_timers[bufnr] = timer
	end
	timer:stop()
	if timer:is_closing() then
		rebuild_timers[bufnr] = nil
		return
	end
	timer:start(
		DEBOUNCE_MS,
		0,
		vim.schedule_wrap(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				M.refresh(bufnr)
			end
		end)
	)
end

-- Register autocmds (idempotent). Called from setup().
function M.setup()
	vim.validate({})
	local group = vim.api.nvim_create_augroup("PyworksMdView", { clear = true })

	vim.api.nvim_create_autocmd({ "BufWinEnter", "WinEnter" }, {
		group = group,
		desc = "Pyworks: apply markdown concealment chrome to notebook windows",
		callback = function(ev)
			if notebook_lsp.is_notebook_buf(ev.buf) then
				-- ev.match is the matched FILE pattern; the window is the
				-- current one during BufWinEnter/WinEnter
				apply_window(vim.api.nvim_get_current_win())
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI", "BufWritePost" }, {
		group = group,
		desc = "Pyworks: debounce-rebuild markdown concealment ranges after edits",
		callback = function(ev)
			if notebook_lsp.is_notebook_buf(ev.buf) then
				schedule_refresh(ev.buf)
			end
		end,
	})

	vim.api.nvim_create_autocmd("WinClosed", {
		group = group,
		desc = "Pyworks: forget concealment match of closed window",
		callback = function(ev)
			local winid = tonumber(ev.match)
			if winid then
				win_matches[winid] = nil
			end
		end,
	})

	vim.api.nvim_create_autocmd({ "BufDelete", "BufWipeout" }, {
		group = group,
		desc = "Pyworks: drop concealment rebuild timer for deleted buffer",
		callback = function(ev)
			local timer = rebuild_timers[ev.buf]
			if timer then
				timer:stop()
				if not timer:is_closing() then
					timer:close()
				end
				rebuild_timers[ev.buf] = nil
			end
		end,
	})

	return true
end

-- Test hooks (private-function convention: M._name)
M._conceal_pattern = conceal_pattern
M._conceal_enabled = conceal_enabled
M._fold_default_enabled = fold_default_enabled

return M
