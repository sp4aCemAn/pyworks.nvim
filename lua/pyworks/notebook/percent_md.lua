-- jupytext percent-format markdown comment codec
--
-- Established fact (docs/UX_MODEL_A_REFACTOR.md, verified against jupytext
-- 1.19.3): py:percent CANONICALLY comments markdown cell content. Codec of
-- reference: jupytext/cell_reader.py::uncomment(lines, "#") and
-- jupytext/languages.py::comment_lines(lines, "#").
--
--   comment:   content line L -> "# " .. L;  empty L -> "#"
--   uncomment: strip leading "# ", else leading "#", else leave the line
--
-- Pure-Lua mirror of that codec so consumers (the markdown formatter, F4,
-- and inline concealment, F6) translate between canonical buffer lines and
-- real markdown text without shelling out.

local M = {}

-- Real markdown content lines -> canonical commented buffer lines.
function M.comment(content_lines)
	vim.validate({ content_lines = { content_lines, "table" } })
	local out = {}
	for i, line in ipairs(content_lines) do
		if line == "" then
			out[i] = "#"
		else
			out[i] = "# " .. line
		end
	end
	return out
end

-- Canonical commented buffer lines -> real markdown content lines.
-- Non-canonical lines (not starting with "#" / "# ") pass through
-- unchanged, matching jupytext's reader. NOTE the documented edge (B19
-- review): a raw UNcommented H1 typed mid-session ("# Title") IS
-- "# "-prefixed, so uncomment strips its "#" and format_cell will
-- re-comment it as paragraph text — jupytext-parity, level is lost.
function M.uncomment(md_lines)
	vim.validate({ md_lines = { md_lines, "table" } })
	local out = {}
	for i, line in ipairs(md_lines) do
		if line:sub(1, 2) == "# " then
			out[i] = line:sub(3)
		elseif line:sub(1, 1) == "#" then
			out[i] = line:sub(2)
		else
			out[i] = line
		end
	end
	return out
end

return M
