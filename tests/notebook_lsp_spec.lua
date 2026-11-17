-- Tests for notebook-aware LSP diagnostics silencing (notebooks.lsp modes)

local sample_lines = {
	"# %% [markdown]",
	"# hello *world*", -- md region line (0-based 1)
	"more md", -- md region line (0-based 2)
	"# %%",
	"import os", -- code cell line (0-based 4)
	"import os", -- code cell line (0-based 5)
}

local function make_notebook_buf(with_var)
	local bufnr = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sample_lines)
	if with_var then
		vim.b[bufnr].pyworks_notebook_path = "/tmp/nb_spec.ipynb"
	end
	return bufnr
end

local function diag(line0)
	return {
		range = {
			start = { line = line0, character = 0 },
			["end"] = { line = line0, character = 1 },
		},
		message = "boom",
		source = "pylsp",
	}
end

describe("notebook lsp", function()
	local notebook_lsp
	local handler_key
	local saved_handler
	local captured

	before_each(function()
		vim.g.pyworks_setup_complete = nil
		package.loaded["pyworks"] = nil
		package.loaded["pyworks.notebook.lsp"] = nil
		notebook_lsp = require("pyworks.notebook.lsp")

		handler_key = "textDocument/publishDiagnostics"
		saved_handler = vim.lsp.handlers[handler_key]
		captured = nil
		-- sentinel "original" handler: records what it receives
		vim.lsp.handlers[handler_key] = function(err, result, ctx)
			captured = { err = err, result = result, ctx = ctx }
		end
	end)

	after_each(function()
		notebook_lsp.uninstall()
		vim.lsp.handlers[handler_key] = saved_handler
	end)

	describe("install/uninstall", function()
		it("should wrap the handler once and restore it on uninstall", function()
			assert.is_true(notebook_lsp.install())
			local wrapped = vim.lsp.handlers[handler_key]
			assert.is_true(notebook_lsp.install() == false, "double install must no-op")

			notebook_lsp.uninstall()
			assert.are_not.same(wrapped, vim.lsp.handlers[handler_key])
		end)

		it("should not wrap when mode is attach", function()
			local pyworks = require("pyworks")
			pyworks.setup({ notebooks = { lsp = "attach" } })

			-- setup() already called install(); the sentinel handler must be
			-- untouched, i.e. publishing goes straight to the original.
			local result = { uri = "file:///x", diagnostics = { diag(1) } }
			vim.lsp.handlers[handler_key](nil, result, { bufnr = make_notebook_buf(true) })
			assert.same(result.diagnostics, captured.result.diagnostics, "attach mode must passthrough")
		end)
	end)

	describe("silence mode", function()
		before_each(function()
			notebook_lsp.install()
		end)

		it("should drop diagnostics inside markdown regions and keep code ones", function()
			local bufnr = make_notebook_buf(true)
			vim.lsp.handlers[handler_key](nil, {
				uri = "file:///nb",
				diagnostics = { diag(1), diag(2), diag(4), diag(5) },
			}, { bufnr = bufnr })

			local kept = captured.result.diagnostics
			assert.equals(2, #kept)
			assert.equals(4, kept[1].range.start.line)
			assert.equals(5, kept[2].range.start.line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should pass the payload through unmutated when nothing is dropped", function()
			local bufnr = make_notebook_buf(true)
			local result = { uri = "file:///nb", diagnostics = { diag(4), diag(5) } }
			vim.lsp.handlers[handler_key](nil, result, { bufnr = bufnr })

			assert.is_true(captured.result == result, "no-drop path must forward the original table")

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should resolve the buffer from the params URI when ctx.bufnr is absent (nvim 0.12)", function()
			-- Neovim >=0.12 hands publishDiagnostics ctx WITHOUT a resolved
			-- bufnr; trusting ctx.bufnr alone silently disables the filter
			-- (real-world leak against the user's pylsp).
			local path = vim.fn.tempname() .. "_uri.ipynb"
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sample_lines)
			vim.api.nvim_buf_set_name(bufnr, path)
			vim.b[bufnr].pyworks_notebook_path = path

			notebook_lsp.install()
			vim.lsp.handlers[handler_key](nil, {
				uri = "file://" .. path,
				diagnostics = { diag(1), diag(4) },
			}, { client_id = 1, method = handler_key })

			assert.equals(1, #captured.result.diagnostics)
			assert.equals(4, captured.result.diagnostics[1].range.start.line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
			os.remove(path)
		end)

		it("should forward everything for non-notebook buffers", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, sample_lines)
			vim.lsp.handlers[handler_key](nil, {
				uri = "file:///plain.py",
				diagnostics = { diag(1), diag(2) },
			}, { bufnr = bufnr })

			assert.equals(2, #captured.result.diagnostics)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should tolerate invalid buffers and empty payloads", function()
			assert.has_no.errors(function()
				vim.lsp.handlers[handler_key](
					nil,
					{ uri = "file:///gone", diagnostics = { diag(1) } },
					{ bufnr = 999999 }
				)
				vim.lsp.handlers[handler_key](nil, { uri = "file:///nb", diagnostics = {} }, {
					bufnr = make_notebook_buf(true),
				})
			end)
		end)

		it("should drop pylsp-pyflakes whole-file 'invalid syntax' on md content lines (EOF cell too)", function()
			-- Mirrors the real-world repro: 80 code lines, markers at
			-- 1-based 81/83 with raw md at 82 and 84 (last cell to EOF).
			-- pylsp's pyflakes plugin reports the parse failure at the
			-- first offending line (0-based 81 and beyond).
			local lines = {}
			for i = 1, 80 do
				table.insert(lines, "x" .. i .. " = 1")
			end
			table.insert(lines, "# %% [markdown]") -- 81
			table.insert(lines, "this is a test") -- 82
			table.insert(lines, "# %% [markdown]") -- 83
			table.insert(lines, "another raw line") -- 84

			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
			vim.b[bufnr].pyworks_notebook_path = "/tmp/graph/test.ipynb"

			vim.lsp.handlers[handler_key](nil, {
				uri = "file:///graph/test.ipynb",
				diagnostics = { diag(81), diag(83), diag(5) },
			}, { bufnr = bufnr })

			local kept = captured.result.diagnostics
			assert.equals(1, #kept)
			assert.equals(5, kept[1].range.start.line, "only the code-cell diagnostic may survive")

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("attach_client", function()
		it("should wrap a running client's handlers exactly once and filter via them", function()
			local forwarded = {}
			local client = {
				handlers = {
					["textDocument/publishDiagnostics"] = function(err, result, ctx)
						table.insert(forwarded, #(result.diagnostics or {}))
					end,
				},
			}

			assert.is_true(notebook_lsp.attach_client(client))
			assert.is_false(notebook_lsp.attach_client(client), "must not double-wrap")

			local bufnr = make_notebook_buf(true)
			client.handlers[handler_key](nil, { diagnostics = { diag(1), diag(4) } }, { bufnr = bufnr })
			assert.same({ 1 }, forwarded, "md-region diagnostic must be filtered for this client too")

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("detach mode (maybe_detach)", function()
		before_each(function()
			package.loaded["pyworks"] = {
				get_config = function()
					return { notebooks = { lsp = "detach" } }
				end,
			}
		end)

		it("should detach 0.11-style clients from notebook buffers only", function()
			local bufnr = make_notebook_buf(true)
			local detached = {}
			local client = {
				id = 42,
				detach_buffer = function(_, b)
					table.insert(detached, b)
				end,
			}
			assert.is_true(notebook_lsp.maybe_detach(bufnr, client))
			assert.same({ bufnr }, detached)

			local plain = vim.api.nvim_create_buf(false, true)
			assert.is_false(notebook_lsp.maybe_detach(plain, client))
			assert.equals(1, #detached, "non-notebook buffers must not be detached")

			vim.api.nvim_buf_delete(bufnr, { force = true })
			vim.api.nvim_buf_delete(plain, { force = true })
		end)

		it("should fall back to buf_detach_client for 0.10-style clients", function()
			local bufnr = make_notebook_buf(true)
			local seen = {}
			local orig = vim.lsp.buf_detach_client
			vim.lsp.buf_detach_client = function(b, id)
				seen = { buf = b, id = id }
			end
			local detached_ok = notebook_lsp.maybe_detach(bufnr, { id = 7 })
			vim.lsp.buf_detach_client = orig

			assert.is_true(detached_ok)
			assert.equals(bufnr, seen.buf)
			assert.equals(7, seen.id)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should be inert in silence mode", function()
			package.loaded["pyworks"] = {
				get_config = function()
					return { notebooks = { lsp = "silence" } }
				end,
			}
			local bufnr = make_notebook_buf(true)
			local called = false
			local client = {
				id = 1,
				detach_buffer = function()
					called = true
				end,
			}
			assert.is_false(notebook_lsp.maybe_detach(bufnr, client))
			assert.is_false(called)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("_is_notebook_buf", function()
		it("should detect via buffer var and via .ipynb buffer name", function()
			local by_var = make_notebook_buf(true)
			assert.is_true(notebook_lsp._is_notebook_buf(by_var))

			local by_name = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(by_name, vim.fn.tempname() .. ".ipynb")
			assert.is_true(notebook_lsp._is_notebook_buf(by_name))

			local plain = vim.api.nvim_create_buf(false, true)
			assert.is_false(notebook_lsp._is_notebook_buf(plain))
			assert.is_false(notebook_lsp._is_notebook_buf(999999))

			vim.api.nvim_buf_delete(by_var, { force = true })
			vim.api.nvim_buf_delete(by_name, { force = true })
			vim.api.nvim_buf_delete(plain, { force = true })
		end)
	end)
end)
