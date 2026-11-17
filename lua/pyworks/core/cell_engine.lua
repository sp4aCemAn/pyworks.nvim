local M = {}

local ui = require("pyworks.ui")

local config = {
	cell_marker = "# %%",
}

function M.configure(opts)
	vim.validate({ opts = { opts, "table", true } })
	config = vim.tbl_deep_extend("force", config, opts or {})
end

function M.get_cell_pattern()
	return "^" .. vim.pesc(config.cell_marker)
end

-- Raw configured marker text (e.g. "# %%"), for callers building their own
-- regexes around the marker itself.
function M.get_marker()
	vim.validate({})
	return config.cell_marker
end

-- Escape characters that are special WITHOUT a backslash in vim's default
-- magic regex mode (`. * [ ^ $ ~`). Everything else in a typical marker
-- (`%`, `-`, `(`, `)`, `|`, `#`) is literal in magic mode, so it must stay
-- untouched — e.g. `%` cannot be written as `\%` (that leads-in an atom).
local function vim_regex_escape(s)
	return (s:gsub("\\", "\\\\"):gsub("[%^%$%.%*%[~]", "\\%0"))
end

-- Vim-regex pattern for use with vim.fn.search(). Exported so keymaps.lua
-- can use the configured marker instead of hardcoding "^# %%".
function M.vim_search_pattern()
	return "^" .. vim_regex_escape(config.cell_marker)
end

-- Keep the local alias for internal use.
local function vim_search_pattern()
	return M.vim_search_pattern()
end

-- Content range of the cell under the cursor (markers excluded; cursor ON a
-- marker line selects the cell it opens). nil, nil for empty cells — a cell
-- whose content is blank-only counts as empty (running it would evaluate
-- whitespace).
-- Call-through to the canonical cell model (F3).
function M.find_cell_boundaries()
	local cell = require("pyworks.core.cell_model").cell_at(0)
	if not cell or cell.start_line > cell.end_line then
		return nil, nil
	end
	local lines = vim.api.nvim_buf_get_lines(0, cell.start_line - 1, cell.end_line, false)
	for _, line in ipairs(lines) do
		if line:match("%S") then
			return cell.start_line, cell.end_line
		end
	end
	return nil, nil
end

function M.count_cells(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	return #require("pyworks.core.cell_model").markers(bufnr)
end

function M.get_cell_positions(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	local positions = {}
	for _, cell in ipairs(require("pyworks.core.cell_model").markers(bufnr)) do
		table.insert(positions, cell.marker_line)
	end
	return positions
end

-- Line ranges of markdown cell *content*: marker line and the following
-- marker are excluded; the final cell extends to end of buffer. Empty cells
-- produce no region. Delegated to core/cell_model.markdown_regions (the
-- canonical cell model, F1); kept as the cell_engine API for existing
-- consumers.
function M.get_markdown_regions(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	return require("pyworks.core.cell_model").markdown_regions(bufnr)
end

-- True when the cursor is inside (or on the marker of) a markdown cell.
-- Type comes from the cell model (F3) — no cursor-position marker search.
function M.is_markdown_cell()
	local cell = require("pyworks.core.cell_model").cell_at(0)
	return cell ~= nil and cell.type == "markdown"
end

function M.next_cell()
	local pattern = vim_search_pattern()
	local next_marker = vim.fn.search(pattern, "nW")
	if next_marker == 0 then
		return false
	end
	ui.enter_cell(next_marker, { insert_mode = false })
	return true
end

function M.prev_cell()
	local pattern = vim_search_pattern()
	local current_marker = vim.fn.search(pattern, "bcnW")
	if current_marker == 0 then
		return false
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	vim.api.nvim_win_set_cursor(0, { current_marker, 0 })
	local prev_marker = vim.fn.search(pattern, "bnW")
	if prev_marker == 0 or prev_marker == current_marker then
		vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
		return false
	end
	ui.enter_cell(prev_marker, { insert_mode = false })
	return true
end

-- Refuse to mutate a nomodifiable buffer: mapped keymaps would otherwise
-- raise raw errors from deep inside nvim_buf_set_lines/append.
local function ensure_modifiable()
	if not vim.bo.modifiable then
		vim.notify("Buffer is not modifiable", vim.log.levels.WARN)
		return false
	end
	return true
end

function M.insert_cell_above()
	if not ensure_modifiable() then
		return
	end
	local pattern = vim_search_pattern()
	local current_marker = vim.fn.search(pattern, "bcnW")
	local insert_line
	if current_marker == 0 then
		insert_line = 0
	else
		insert_line = current_marker - 1
	end
	vim.fn.append(insert_line, { config.cell_marker, "" })
	ui.enter_cell(insert_line + 1, { insert_mode = false })
end

function M.insert_cell_below()
	if not ensure_modifiable() then
		return
	end
	local pattern = vim_search_pattern()
	local next_marker = vim.fn.search(pattern, "nW")
	local insert_line
	if next_marker == 0 then
		insert_line = vim.fn.line("$")
	else
		insert_line = next_marker - 1
	end
	vim.fn.append(insert_line, { config.cell_marker, "" })
	ui.enter_cell(insert_line + 1, { insert_mode = false })
end

function M.insert_markdown_above()
	if not ensure_modifiable() then
		return
	end
	local pattern = vim_search_pattern()
	local current_marker = vim.fn.search(pattern, "bcnW")
	local insert_line
	if current_marker == 0 then
		insert_line = 0
	else
		insert_line = current_marker - 1
	end
	vim.fn.append(insert_line, { config.cell_marker .. " [markdown]", "" })
	ui.enter_cell(insert_line + 1, { insert_mode = false })
end

function M.insert_markdown_below()
	if not ensure_modifiable() then
		return
	end
	local pattern = vim_search_pattern()
	local next_marker = vim.fn.search(pattern, "nW")
	local insert_line
	if next_marker == 0 then
		insert_line = vim.fn.line("$")
	else
		insert_line = next_marker - 1
	end
	vim.fn.append(insert_line, { config.cell_marker .. " [markdown]", "" })
	ui.enter_cell(insert_line + 1, { insert_mode = false })
end

function M.toggle_cell_type()
	if not ensure_modifiable() then
		return
	end
	local pattern = vim_search_pattern()
	local cell_start = vim.fn.search(pattern, "bcnW")
	if cell_start == 0 then
		return false
	end
	local line = vim.fn.getline(cell_start)
	local new_line
	if line:match("%[markdown%]") then
		-- markdown -> code: strip the tag, keep any title text
		new_line = (line:gsub("%s*%[markdown%]", "", 1))
	else
		-- code -> markdown: insert the tag between marker and title
		local marker_prefix = vim.pesc(config.cell_marker)
		local rest = line:match("^" .. marker_prefix .. "%s*(.*)$") or ""
		if rest ~= "" then
			new_line = config.cell_marker .. " [markdown] " .. rest
		else
			new_line = config.cell_marker .. " [markdown]"
		end
	end
	vim.api.nvim_buf_set_lines(0, cell_start - 1, cell_start, false, { new_line })
	return true
end

function M.merge_cell_below()
	if not ensure_modifiable() then
		return false
	end
	local pattern = vim_search_pattern()
	local next_marker = vim.fn.search(pattern, "nW")
	if next_marker == 0 then
		return false
	end
	vim.api.nvim_buf_set_lines(0, next_marker - 1, next_marker, false, {})
	return true
end

function M.split_cell()
	if not ensure_modifiable() then
		return
	end
	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	vim.fn.append(cursor_line - 1, { config.cell_marker })
end

-- Execute the current # %% cell via Molten.
-- opts.advance = true moves the cursor to the next cell after dispatching
-- (matches the classic Jupyter Shift+Enter behavior).
-- Returns true on success, false if there is no initialized kernel or the
-- cell is empty.
function M.run_cell(opts)
	vim.validate({ opts = { opts, "table", true } })
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()

	if not vim.b[bufnr].molten_initialized then
		vim.notify("No kernel initialized. Run :PyworksSetup or press <leader>jl first.", vim.log.levels.WARN)
		return false
	end

	local start_line, end_line = M.find_cell_boundaries()
	if not start_line then
		vim.notify("Empty cell", vim.log.levels.WARN)
		return false
	end

	local cell_num = ui.get_current_cell_number()
	ui.mark_cell_executed(cell_num)

	local ok = pcall(vim.fn.MoltenEvaluateRange, start_line, end_line)
	if not ok then
		vim.fn.setpos("'<", { 0, start_line, 1, 0 })
		vim.fn.setpos("'>", { 0, end_line, vim.fn.col({ end_line, "$" }) - 1, 0 })
		pcall(vim.cmd, "'<,'>MoltenEvaluateVisual")
	end

	if opts.advance then
		vim.defer_fn(function()
			-- The user may have switched buffers during the settle delay;
			-- the advance must never jump a cursor in the wrong buffer
			if vim.api.nvim_get_current_buf() ~= bufnr then
				return
			end
			local found = vim.fn.search(vim_search_pattern(), "W")
			if found == 0 then
				vim.notify("Last cell", vim.log.levels.INFO)
			else
				ui.enter_cell(found, { insert_mode = false })
			end
		end, 100)
	end

	return true
end

return M
