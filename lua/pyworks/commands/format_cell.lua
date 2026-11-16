-- Markdown cell formatting command
--
-- Runs the configured notebooks.md_formatter (argv; default pandoc) over
-- the *content* of the markdown cell under the cursor (marker lines are
-- left untouched — jupytext owns those) and replaces the region with the
-- formatter's stdout. Async; the buffer is only touched on exit code 0.

local M = {}

local cell_engine = require("pyworks.core.cell_engine")
local notifications = require("pyworks.core.notifications")
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

-- Markdown cell containing the cursor (marker line counts as inside).
-- Content region: marker_line+1 .. next_marker-1 (or EOF). nil when the
-- cursor is outside any cell or inside a code cell.
local function find_enclosing_md_region(bufnr, cursor_line)
	local positions = cell_engine.get_cell_positions(bufnr)
	local line_count = vim.api.nvim_buf_line_count(bufnr)
	for idx, marker_line in ipairs(positions) do
		local boundary = positions[idx + 1] or (line_count + 1)
		if cursor_line >= marker_line and cursor_line < boundary then
			local marker_text = vim.api.nvim_buf_get_lines(bufnr, marker_line - 1, marker_line, false)[1] or ""
			if not marker_text:match("%[markdown%]") then
				return nil
			end
			local start_line = marker_line + 1
			local end_line = boundary - 1
			if start_line > end_line then
				return nil
			end
			return { start_line = start_line, end_line = end_line }
		end
	end
	return nil
end

function M.format_current_cell(callback)
	vim.validate({ callback = { callback, "function", true } })

	local bufnr = vim.api.nvim_get_current_buf()
	if vim.bo[bufnr].modifiable == false then
		notifications.notify("Cannot format: buffer is not modifiable", vim.log.levels.WARN)
		return false
	end

	local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
	local region = find_enclosing_md_region(bufnr, cursor_line)
	if not region then
		notifications.notify("Cursor is not inside a markdown cell", vim.log.levels.INFO)
		return false
	end

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

	local lines = vim.api.nvim_buf_get_lines(bufnr, region.start_line - 1, region.end_line, false)
	local content = table.concat(lines, "\n") .. "\n"

	local ok_start, _ = utils.async_system_call(formatter, function(success, stdout, stderr)
		if not success then
			notifications.notify_error("Markdown formatter failed: " .. vim.trim(stderr or ""))
			if callback then
				callback(false)
			end
			return
		end

		local new_lines = vim.split(stdout or "", "\n", { plain = true })
		if new_lines[#new_lines] == "" then
			table.remove(new_lines)
		end
		if not vim.api.nvim_buf_is_valid(bufnr) then
			if callback then
				callback(false)
			end
			return
		end

		vim.api.nvim_buf_set_lines(bufnr, region.start_line - 1, region.end_line, false, new_lines)
		notifications.notify("Markdown cell formatted", vim.log.levels.INFO)
		if callback then
			callback(true)
		end
	end, { stdin = content })

	if not ok_start then
		notifications.notify_error("Failed to start markdown formatter")
		return false
	end

	return true
end

vim.api.nvim_create_user_command("PyworksFormatMarkdownCell", function()
	M.format_current_cell()
end, {
	desc = "Format the markdown cell under the cursor with notebooks.md_formatter",
})

M._find_enclosing_md_region = find_enclosing_md_region

return M
