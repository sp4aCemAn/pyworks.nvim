-- Notebook-aware LSP diagnostics handling for pyworks.nvim
--
-- jupytext's percent format stores markdown cell bodies as RAW text, which
-- is invalid Python: servers (pylsp, pyright) report syntax errors on those
-- lines and the parse failures cascade into bogus scope/undefined warnings
-- inside real code cells. With notebooks.lsp = "silence" (the default) we
-- wrap the publishDiagnostics handler and drop diagnostics that point into
-- markdown cell regions; everything else passes through untouched.
--
-- "detach" (S4) is implemented via an LspAttach autocmd in plugin/pyworks.lua.
-- "attach" disables this module entirely (status-quo passthrough).

local M = {}

local original_handler = nil
local installed = false

-- Notebook buffers are identified by the buffer variable set in
-- read_notebook (jupytext.lua); the buffer name is a fallback for
-- session-restore paths where the variable has not been set yet.
local function is_notebook_buf(bufnr)
	if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
		return false
	end
	local ok, path = pcall(vim.api.nvim_buf_get_var, bufnr, "pyworks_notebook_path")
	if ok and type(path) == "string" and path ~= "" then
		return true
	end
	return vim.api.nvim_buf_get_name(bufnr):match("%.ipynb$") ~= nil
end

local function get_mode()
	-- Lazy require mirrors the get_packages() cycle-breaking pattern:
	-- init.lua -> notebook.lsp -> (handler, later) -> init.lua
	local ok, pyworks = pcall(require, "pyworks")
	if not ok or type(pyworks.get_config) ~= "function" then
		return "silence"
	end
	local cfg = pyworks.get_config()
	return (cfg.notebooks and cfg.notebooks.lsp) or "silence"
end

-- 0-based diagnostic line -> 1-based region check
local function line_in_regions(line0, regions)
	local line1 = line0 + 1
	for _, r in ipairs(regions) do
		if line1 >= r.start_line and line1 <= r.end_line then
			return true
		end
	end
	return false
end

local function filter_diagnostics(bufnr, diagnostics)
	local cell_engine = require("pyworks.core.cell_engine")
	local ok_regions, regions = pcall(cell_engine.get_markdown_regions, bufnr)
	if not ok_regions or #regions == 0 then
		return diagnostics
	end

	local kept = {}
	local dropped = 0
	for _, diagnostic in ipairs(diagnostics) do
		local start = diagnostic.range and diagnostic.range.start
		if start and type(start.line) == "number" and line_in_regions(start.line, regions) then
			dropped = dropped + 1
		else
			table.insert(kept, diagnostic)
		end
	end
	return kept, dropped
end

local PUBLISH = "textDocument/publishDiagnostics"

-- functions cannot be indexed in Lua 5.1 without a metatable, so track
-- wrapped handlers in a weak-keyed set instead of a flag field
local wrapped_handlers = setmetatable({}, { __mode = "k" })

local function make_wrapper(original)
	if type(original) ~= "function" or wrapped_handlers[original] then
		return nil
	end
	local wrapper = function(err, result, ctx, config)
		if get_mode() ~= "silence" or not is_notebook_buf(ctx.bufnr) or type(result) ~= "table" then
			return original(err, result, ctx, config)
		end

		local filtered, dropped = filter_diagnostics(ctx.bufnr, result.diagnostics or {})
		if dropped == 0 then
			return original(err, result, ctx, config)
		end

		-- Shallow-copy the payload so we never mutate the object other
		-- handlers (or the server adapter) may still be holding.
		local patched = {
			uri = result.uri,
			kind = result.kind,
			diagnostics = filtered,
		}
		return original(err, patched, ctx, config)
	end
	wrapped_handlers[wrapper] = true
	return wrapper
end

function M.install()
	if installed then
		return false
	end
	if get_mode() == "attach" then
		return false
	end

	original_handler = vim.lsp.handlers[PUBLISH]
	local wrapper = make_wrapper(original_handler)
	if not wrapper then
		return false
	end
	vim.lsp.handlers[PUBLISH] = wrapper
	installed = true

	-- Clients snapshot vim.lsp.handlers at start time; anything already
	-- running (e.g. pylsp attached to a .py file before this notebook-only
	-- lazy load fires) needs the wrapper on its own handler table.
	if vim.lsp.get_clients then
		for _, client in ipairs(vim.lsp.get_clients()) do
			pcall(M.attach_client, client)
		end
	end

	return true
end

-- Wrap an already-started client's publishDiagnostics handler. Idempotent;
-- called from install() and from the LspAttach autocmd in plugin/.
function M.attach_client(client)
	vim.validate({ client = { client, "table" } })
	if type(client.handlers) ~= "table" or get_mode() ~= "silence" then
		return false
	end
	local wrapper = make_wrapper(client.handlers[PUBLISH])
	if not wrapper then
		return false
	end
	client.handlers[PUBLISH] = wrapper
	return true
end

function M.uninstall()
	if not installed then
		return false
	end
	vim.lsp.handlers["textDocument/publishDiagnostics"] = original_handler
	original_handler = nil
	installed = false
	return true
end

-- Public wrapper so plugin/ and tests share one notebook-detection rule.
function M.is_notebook_buf(bufnr)
	vim.validate({ bufnr = { bufnr, "number" } })
	return is_notebook_buf(bufnr)
end

-- Detach-mode hook, called from the LspAttach autocmd in plugin/pyworks.lua.
-- `client` is a live vim.lsp.Client (or test double with an optional
-- detach_buffer method). No-op unless notebooks.lsp == "detach".
function M.maybe_detach(bufnr, client)
	vim.validate({
		bufnr = { bufnr, "number" },
		client = { client, "table" },
	})
	if get_mode() ~= "detach" or not is_notebook_buf(bufnr) then
		return false
	end
	if type(client.detach_buffer) == "function" then
		-- Neovim 0.11+
		client:detach_buffer(bufnr)
	else
		vim.lsp.buf_detach_client(bufnr, client.id) -- 0.10 fallback (deprecated API)
	end
	return true
end

M._is_notebook_buf = is_notebook_buf
M._filter_diagnostics = filter_diagnostics

return M
