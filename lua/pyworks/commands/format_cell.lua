-- Markdown cell formatting command
--
-- Runs the configured notebooks.md_formatter (argv; default pandoc) over
-- the *content* of the markdown cell under the cursor (marker lines are
-- left untouched — jupytext owns those) and replaces the region with the
-- formatter's stdout. Async; the buffer is only touched on exit code 0.
--
-- Model A round-trip (F4): canonical percent buffers store markdown content
-- COMMENTED ("# text"), so the formatter receives the uncommented real
-- markdown (percent_md.uncomment) and its output is re-commented before
-- replacement — without that codec step a formatter sees "# text" as an H1
-- heading and every pass corrupts the cell ("h1 soup").

local M = {}

local cell_model = require("pyworks.core.cell_model")
local notifications = require("pyworks.core.notifications")
local percent_md = require("pyworks.notebook.percent_md")
local utils = require("pyworks.utils")

local function get_formatter()
	local ok, pyworks = pcall(require, "pyworks")
	local cfg = ok and pyworks.get_config and pyworks.get_config() or nil
	local cmd = cfg and cfg.notebooks and cfg.notebooks.md_formatter
	if type(cmd) ~= "table" or type(cmd[1]) ~= "string" then
		return nil
	end
	return cmd
end

-- Markdown cell containing the cursor (marker line counts as inside, per
-- cell_model.cell_at). Content region = cell start_line .. end_line. nil
-- when the cursor is outside any cell, in the preamble, in an empty cell,
-- or in a non-markdown cell.
local function find_enclosing_md_region(bufnr, cursor_line)
	local cell = cell_model.cell_at(bufnr, cursor_line)
	if not cell or cell.marker_line == 0 or cell.type ~= "markdown" then
		return nil
	end
	if cell.start_line > cell.end_line then
		return nil
	end
	return { start_line = cell.start_line, end_line = cell.end_line }
end

function M.format_current_cell(callback)
	vim.validate({ callback = { callback, "function", true } })

	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].modifiable == false then
		notifications.notify("Cannot format: buffer is not modifiable", vim.log.levels.WARN)
		return false
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local cell = cell_model.cell_at(bufnr, cursor_line)
	if not cell or cell.marker_line == 0 or cell.type ~= "markdown" or cell.start_line > cell.end_line then
		notifications.notify("Cursor is not inside a markdown cell", vim.log.levels.INFO)
		return false
	end
	-- Identity of the cell at dispatch time: the formatter can run up to
	-- 30s, and the callback must never paste output into line numbers that
	-- mid-flight edits have moved.
	local marker_line = cell.marker_line
	local marker_text = cell.marker_text

	local formatter = get_formatter()
	if not formatter then
		notifications.notify("notebooks.md_formatter is not a valid argv list", vim.log.levels.ERROR)
		return false
	end
	if vim.fn.executable(formatter[1]) ~= 1 then
		notifications.notify(
			string.format("Markdown formatter '%s' not found. Install it or set notebooks.md_formatter.", formatter[1]),
			vim.log.levels.WARN,
			{ action_required = true }
		)
		return false
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, cell.start_line - 1, cell.end_line, false)
	local content = table.concat(percent_md.uncomment(lines), "\n") .. "\n"

	local ok_start, _ = utils.async_system_call(formatter, function(success, stdout, stderr)
		if not success then
			notifications.notify_error("Markdown formatter failed: " .. vim.trim(stderr or ""))
			if callback then
				callback(false)
			end
			return
		end

		local new_lines = vim.split(stdout or "", "\n", { plain = true })
		-- Strip exactly ONE trailing newline (the split artifact). Blank
		-- lines BEYOND that are formatter-preserved content (e.g. a
		-- trailing empty md line -> "#") and must survive the round-trip;
		-- stripping all of them loses real empty lines.
		if new_lines[#new_lines] == "" then
			table.remove(new_lines)
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			if callback then
				callback(false)
			end
			return
		end

		-- Re-resolve the cell; if the layout moved under us, bail instead
		-- of writing the output into the wrong lines
		local fresh = cell_model.cell_at(bufnr, marker_line)
		if not fresh or fresh.marker_line ~= marker_line or fresh.marker_text ~= marker_text then
			notifications.notify("Buffer changed while formatting; markdown cell left untouched", vim.log.levels.WARN)
			if callback then
				callback(false)
			end
			return
		end

		local ok_write = pcall(
			vim.api.nvim_buf_set_lines,
			bufnr,
			fresh.start_line - 1,
			fresh.end_line,
			false,
			percent_md.comment(new_lines)
		)
		if not ok_write then
			notifications.notify("Cannot format: buffer is not modifiable", vim.log.levels.WARN)
			if callback then
				callback(false)
			end
			return
		end

		notifications.notify("Markdown cell formatted", vim.log.levels.INFO)
		if callback then
			callback(true)
		end
	end, { stdin = content })

	-- async_system_call already reports spawn failures through the callback
	if not ok_start then
		return false
	end

	return true
end

vim.api.nvim_create_user_command("PyworksFormatMarkdownCell", function(ev)
	if ev.range and ev.range > 1 then
		notifications.notify(
			"Format works on the markdown cell under the cursor; move into the cell and run it without a range",
			vim.log.levels.WARN
		)
		return
	end
	M.format_current_cell()
end, {
	desc = "Format the markdown cell under the cursor with notebooks.md_formatter",
	range = true,
})

M._find_enclosing_md_region = find_enclosing_md_region

return M
