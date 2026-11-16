-- Markdown highlighting inside jupytext percent notebooks
--
-- Notebook buffers are filetype=python, so raw markdown cell bodies get no
-- markdown styling. This adds a top-level syntax region covering each
-- "# %% [markdown]" cell's content (through to the next marker) whose
-- contents are the runtime markdown syntax groups. Treesitter-based
-- setups should prefer markview.nvim (documented in the README); with a
-- python TS parser the markdown lines are parse errors, which is exactly
-- why vim-syntax regions work reliably here.

local M = {}

local function get_marker()
	return require("pyworks.core.cell_engine").get_marker()
end

-- Lazy require (get_packages() pattern) avoids the init.lua -> here cycle.
local function highlight_enabled()
	local ok, pyworks = pcall(require, "pyworks")
	if not ok or type(pyworks.get_config) ~= "function" then
		return true
	end
	local cfg = pyworks.get_config()
	return not (cfg.notebooks and cfg.notebooks.markdown_highlight == false)
end

-- Escape marker text for use inside a \v (very magic) vim regex: every
-- non-alphanumeric byte becomes literal.
local function magic_escape(text)
	return text:gsub("([^%w])", "\\%1")
end

-- Escape for /.../ or '...' delimited syntax patterns.
local function delim_escape(text)
	return (magic_escape(text):gsub("/", "\\/"))
end

-- Both commands are buffer-local and idempotent (same-name redefine), so
-- they run again after every :edit/reload; no module-level state.
function M.setup_buffer(bufnr)
	vim.validate({ bufnr = { bufnr, "number", true } })
	bufnr = bufnr or vim.api.nvim_get_current_buf()

	if not highlight_enabled() then
		return false
	end

	local marker = get_marker()
	local md_syntax = vim.fn.expand("$VIMRUNTIME/syntax/markdown.vim")
	if vim.fn.filereadable(md_syntax) ~= 1 then
		return false
	end
	-- Respect a deliberately disabled syntax engine (vim.g.syntax_on is set
	-- by $VIMRUNTIME/syntax/syntax.vim); do not turn highlighting on behind
	-- the user's back.
	if vim.g.syntax_on ~= 1 then
		return false
	end

	vim.api.nvim_buf_call(bufnr, function()
		vim.cmd("syntax include @pyworksMD " .. md_syntax)
		-- Start on the marker line but shift the region to the next line
		-- (ms=e+1, glued to the pattern per :syn-pattern-offset) so the
		-- marker itself stays python-comment styled; keepend excludes the
		-- following marker line from the region.
		vim.cmd(
			"syntax region pyworksMdCell"
				.. " start='\\v^"
				.. delim_escape(marker)
				.. ".*\\[markdown\\]'ms=e+1"
				.. " end='\\v^"
				.. delim_escape(marker)
				.. "' keepend"
				.. " contains=@pyworksMD"
		)
	end)

	vim.b[bufnr].pyworks_md_hl_set = true
	return true
end

M._magic_escape = magic_escape

return M
