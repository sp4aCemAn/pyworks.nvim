-- Canonical cell model for percent-format buffers.
--
-- Model A doctrine: the jupytext percent script IS the notebook buffer, and
-- every consumer (run-all, navigation, folds, numbering, LSP markdown
-- silencing, the md formatter) must derive cell structure from ONE source of
-- truth instead of hand-rolling marker searches. That source of truth is
-- here.
--
-- A cell is the table
--   { index, marker_line, type, start_line, end_line, marker_text }
-- with (all lines 1-based buffer lines):
--   - index:       position in the notebook; 0 for the preamble
--   - marker_line: line of the cell marker (0 for the preamble)
--   - type:        "code" | "markdown" | "raw" (from the marker text)
--   - start_line:  first content line (marker_line + 1)
--   - end_line:    last content line (next marker - 1, or the last buffer
--                  line for the final cell); start_line > end_line == empty
--   - marker_text: full marker line (absent for the preamble)
--
-- The preamble (lines before the first marker) is implicit cell 0, present
-- iff such lines exist — for a markerless buffer that is the whole file
-- (which keeps run_cell's historical "no markers -> whole file" semantics).
--
-- Marker detection is routed through cell_engine so custom markers (e.g.
-- "# COMMAND ----------") work; the cross-module requires are lazy both ways
-- (cell_engine.get_markdown_regions delegates back here), mirroring the
-- languages/python <-> core/packages get_packages() cycle-break pattern.

local M = {}

local function get_cell_engine()
	return require("pyworks.core.cell_engine")
end

local function classify_marker(marker_text)
	if marker_text:match("%[markdown%]") then
		return "markdown"
	end
	if marker_text:match("%[raw%]") then
		return "raw"
	end
	return "code"
end

local function resolve_bufnr(bufnr)
	if not bufnr or bufnr == 0 then
		return vim.api.nvim_get_current_buf()
	end
	return bufnr
end

-- Ordered cells for a buffer: preamble cell 0 (only when it has lines),
-- then one cell per marker in order. Empty table for invalid buffers.
function M.for_buffer(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	bufnr = resolve_bufnr(bufnr)
	if not vim.api.nvim_buf_is_valid(bufnr) then
		return {}
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local line_count = math.max(#lines, 1)
	local pattern = get_cell_engine().get_cell_pattern()

	local markers = {}
	for i, line in ipairs(lines) do
		if line:match(pattern) then
			table.insert(markers, { line = i, text = line })
		end
	end

	local cells = {}
	local preamble_end = (markers[1] and (markers[1].line - 1)) or line_count
	if preamble_end >= 1 then
		table.insert(cells, {
			index = 0,
			marker_line = 0,
			type = "code",
			start_line = 1,
			end_line = preamble_end,
		})
	end

	for idx, marker in ipairs(markers) do
		local next_marker = markers[idx + 1]
		table.insert(cells, {
			index = idx,
			marker_line = marker.line,
			type = classify_marker(marker.text),
			start_line = marker.line + 1,
			end_line = (next_marker and (next_marker.line - 1)) or line_count,
			marker_text = marker.text,
		})
	end
	return cells
end

-- Marker cells only (no preamble), in order.
function M.markers(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	local cells = {}
	for _, cell in ipairs(M.for_buffer(bufnr)) do
		if cell.marker_line > 0 then
			table.insert(cells, cell)
		end
	end
	return cells
end

-- Cell containing `line`, defaulting to the cursor line of window 0 (pass an
-- explicit line when querying a buffer other than the current one). A marker
-- line belongs to the cell it opens — matching the "bcnW" navigation
-- semantics every consumer already relies on. nil for lines past the buffer.
function M.cell_at(bufnr, line)
	vim.validate({
		bufnr = { bufnr, "number", true },
		line = { line, "number", true },
	})
	line = line or vim.api.nvim_win_get_cursor(0)[1]
	for _, cell in ipairs(M.for_buffer(bufnr)) do
		if
			(cell.marker_line > 0 and cell.marker_line == line) or (line >= cell.start_line and line <= cell.end_line)
		then
			return cell
		end
	end
	return nil
end

-- Cheap single-line marker test for fold expressions (which run per line;
-- full structure always comes from for_buffer).
function M.is_marker_line(bufnr, line)
	vim.validate({
		bufnr = { bufnr, "number", true },
		line = { line, "number" },
	})
	bufnr = resolve_bufnr(bufnr)
	local lines = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)
	if #lines == 0 then
		return false
	end
	return lines[1]:match(get_cell_engine().get_cell_pattern()) ~= nil
end

-- Content-line ranges of markdown cells (markers excluded, empty cells
-- produce no region, final cell extends to EOF). Source of truth for the
-- notebook LSP silencer and the markdown-cell formatter.
function M.markdown_regions(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	local regions = {}
	for _, cell in ipairs(M.markers(bufnr)) do
		if cell.type == "markdown" and cell.start_line <= cell.end_line then
			table.insert(regions, { start_line = cell.start_line, end_line = cell.end_line })
		end
	end
	return regions
end

return M
