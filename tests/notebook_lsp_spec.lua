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
