-- Notebook-aware LSP diagnostics handling for pyworks.nvim
--
-- Canonical jupytext percent output COMMENTS markdown cell bodies (they are
-- valid Python), but any raw line typed mid-session — or any non-canonical
-- percent file — makes the Python server emit a whole-file `invalid syntax`
-- at the first offending line, cascading into bogus scope/undefined
-- warnings across real code cells. With notebooks.lsp = "silence" (the
-- default) we wrap the publishDiagnostics handler and drop diagnostics that
-- point inside markdown-cell content regions (core/cell_model.markdown_regions,
-- F4); everything else passes through untouched.
--
-- "detach" is implemented via an LspAttach autocmd in plugin/pyworks.lua.
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
	local cell_model = require("pyworks.core.cell_model")
	local ok_regions, regions = pcall(cell_model.markdown_regions, bufnr)
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

-- Neovim >=0.12 passes ctx.bufnr = nil for publishDiagnostics (the default
-- diagnostic handler resolves the buffer from the params URI itself), so a
-- notebook check that trusts ctx.bufnr alone silently disables the filter.
-- Mirror core: ctx.bufnr first, then uri -> buffer.
local function resolve_bufnr(ctx, result)
	local bufnr = ctx and ctx.bufnr
	if bufnr and bufnr > 0 and bufnr ~= -1 and vim.api.nvim_buf_is_valid(bufnr) then
		return bufnr
	end
	if type(result) == "table" and type(result.uri) == "string" then
		local ok, resolved = pcall(vim.uri_to_bufnr, result.uri)
		if ok and resolved and resolved > 0 and vim.api.nvim_buf_is_valid(resolved) then
			return resolved
		end
	end
	return nil
end

-- functions cannot be indexed in Lua 5.1 without a metatable, so track
-- original->wrapper pairs in a weak-keyed map plus a weak set of wrappers:
--  - a client whose handler is ALREADY our wrapper: no-op (no double-wrap)
--  - two clients sharing one original handler function: BOTH get the same
--    wrapper (re-wrapping must yield the existing wrapper, not nil — the
--    second client would otherwise go unfiltered)
local original_to_wrapper = setmetatable({}, { __mode = "k" })
local wrappers = setmetatable({}, { __mode = "k" })

local function make_wrapper(original)
	if type(original) ~= "function" then
		return nil
	end
	if wrappers[original] then
		-- Already one of our wrappers: the caller's table is wrapped
		return nil
	end
	local existing = original_to_wrapper[original]
	if existing then
		return existing
	end
	local wrapper = function(err, result, ctx, config)
		if get_mode() ~= "silence" or type(result) ~= "table" then
			return original(err, result, ctx, config)
		end
		local bufnr = resolve_bufnr(ctx, result)
		if not bufnr or not is_notebook_buf(bufnr) then
			return original(err, result, ctx, config)
		end

		local filtered, dropped = filter_diagnostics(bufnr, result.diagnostics or {})
		if dropped == 0 then
			return original(err, result, ctx, config)
		end

		-- Shallow-copy the payload so we never mutate the object other
		-- handlers (or the server adapter) may still be holding. Forward
		-- any extra fields (LSP 3.15+ publishDiagnostics carries `version`)
		-- instead of rebuilding a partial payload.
		local patched = vim.tbl_extend("force", result, { diagnostics = filtered })
		return original(err, patched, ctx, config)
	end
	wrappers[wrapper] = true
	original_to_wrapper[original] = wrapper
	return wrapper
end

-- clients we wrapped via attach_client -> their pre-wrap handler, so
-- uninstall() can unwrap per-client tables too (not just the global one)
local wrapped_clients = setmetatable({}, { __mode = "k" })

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
	local original = client.handlers[PUBLISH]
	local wrapper = make_wrapper(original)
	if not wrapper then
		return false
	end
	client.handlers[PUBLISH] = wrapper
	wrapped_clients[client] = original
	return true
end

function M.uninstall()
	if not installed then
		return false
	end
	-- Unwrap per-client handler tables first (only where ours is still
	-- installed — a restarted client's fresh table is left alone)
	for client, original in pairs(wrapped_clients) do
		if client.handlers and client.handlers[PUBLISH] == original_to_wrapper[original] then
			client.handlers[PUBLISH] = original
		end
		wrapped_clients[client] = nil
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
