-- Test suite for pyworks.notebook.jupytext module
-- Tests notebook handling, jupytext.nvim detection, and CLI integration

local jupytext = require("pyworks.notebook.jupytext")

describe("jupytext", function()
	describe("is_jupytext_installed", function()
		it("should return boolean", function()
			local result = jupytext.is_jupytext_installed()
			assert.is_boolean(result)
		end)

		it("should check PATH for jupytext executable", function()
			-- This test verifies the function doesn't error
			-- Actual result depends on system state
			local ok, result = pcall(jupytext.is_jupytext_installed)
			assert.is_true(ok)
			assert.is_boolean(result)
		end)
	end)

	describe("find_jupytext_cli", function()
		it("should return string or nil", function()
			local result = jupytext.find_jupytext_cli()
			if result then
				assert.is_string(result)
			else
				assert.is_nil(result)
			end
		end)
	end)

	describe("get_python_for_jupytext", function()
		it("should return a python path", function()
			local result = jupytext.get_python_for_jupytext()
			assert.is_string(result)
			-- Should end with python or python3
			assert.is_true(result:match("python") ~= nil)
		end)

		it("should handle nil filepath", function()
			local ok, result = pcall(jupytext.get_python_for_jupytext, nil)
			assert.is_true(ok)
			assert.is_string(result)
		end)
	end)

	describe("configure_notebook_handler", function()
		it("should return boolean indicating success", function()
			local result = jupytext.configure_notebook_handler()
			assert.is_boolean(result)
		end)

		it("should set up BufReadCmd autocmd for .ipynb files", function()
			jupytext.configure_notebook_handler()

			-- Check that autocmd was created
			local autocmds = vim.api.nvim_get_autocmds({
				group = "PyworksNotebook",
				event = "BufReadCmd",
				pattern = "*.ipynb",
			})
			assert.is_true(#autocmds > 0)
		end)

		it("should set up BufWriteCmd autocmd for .ipynb files", function()
			jupytext.configure_notebook_handler()

			-- Check that autocmd was created
			local autocmds = vim.api.nvim_get_autocmds({
				group = "PyworksNotebook",
				event = "BufWriteCmd",
				pattern = "*.ipynb",
			})
			assert.is_true(#autocmds > 0)
		end)
	end)

	describe("setup_notebook_handler", function()
		it("should create PyworksNotebook augroup", function()
			jupytext.setup_notebook_handler()

			-- Verify augroup exists by trying to get autocmds from it
			local ok = pcall(vim.api.nvim_get_autocmds, { group = "PyworksNotebook" })
			assert.is_true(ok)
		end)

		it("should clear existing autocmds before creating new ones", function()
			-- Call twice to ensure no duplicate autocmds
			jupytext.setup_notebook_handler()
			jupytext.setup_notebook_handler()

			local autocmds = vim.api.nvim_get_autocmds({
				group = "PyworksNotebook",
				event = "BufReadCmd",
				pattern = "*.ipynb",
			})
			-- Should only have one autocmd, not two
			assert.equals(1, #autocmds)
		end)
	end)

	describe("reload_notebook", function()
		it("should return false for non-notebook files", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(bufnr, "/tmp/test.py")
			vim.api.nvim_set_current_buf(bufnr)

			local result = jupytext.reload_notebook(bufnr)
			assert.is_false(result)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)

describe("jupytext atomic save (write_ipynb_content)", function()
	local tmp_base
	local valid_ipynb

	before_each(function()
		tmp_base = vim.fn.tempname()
		vim.fn.mkdir(tmp_base, "p")
		valid_ipynb = '{"cells": [], "metadata": {}, "nbformat": 4, "nbformat_minor": 5}'
	end)

	after_each(function()
		vim.fn.delete(tmp_base, "rf")
	end)

	it("writes valid notebook JSON to the target and leaves no temp file", function()
		local target = tmp_base .. "/nb.ipynb"
		local ok, err = jupytext._write_ipynb_content(target, valid_ipynb)
		assert.is_true(ok)
		assert.is_nil(err)
		assert.equals(1, vim.fn.filereadable(target))
		local decoded = vim.fn.json_decode(vim.fn.readfile(target))
		assert.equals(4, decoded.nbformat)
		assert.equals(0, vim.fn.filereadable(target .. ".tmp"))
	end)

	it("refuses content that is not JSON and leaves the original untouched", function()
		local target = tmp_base .. "/nb.ipynb"
		local original = "original sentinel"
		vim.fn.writefile({ original }, target)

		local ok, err = jupytext._write_ipynb_content(target, "not json at all {{{")
		assert.is_false(ok)
		assert.is_string(err)
		assert.equals(original, table.concat(vim.fn.readfile(target), "\n"))
		assert.equals(0, vim.fn.filereadable(target .. ".tmp"))
	end)

	it("refuses JSON that is not a notebook (no nbformat key)", function()
		local target = tmp_base .. "/nb.ipynb"
		local original = "original sentinel"
		vim.fn.writefile({ original }, target)

		local ok, err = jupytext._write_ipynb_content(target, '{"not": "a notebook"}')
		assert.is_false(ok)
		assert.matches("notebook JSON", err)
		assert.equals(original, table.concat(vim.fn.readfile(target), "\n"))
		assert.equals(0, vim.fn.filereadable(target .. ".tmp"))
	end)

	it("refuses empty and non-string content without touching anything", function()
		local target = tmp_base .. "/nb.ipynb"
		assert.is_false(jupytext._write_ipynb_content(target, ""))
		assert.is_false(jupytext._write_ipynb_content(target, nil))
		assert.equals(0, vim.fn.filereadable(target))
		assert.equals(0, vim.fn.filereadable(target .. ".tmp"))
	end)

	it("fails cleanly when the temp file cannot be created", function()
		local ok, err = jupytext._write_ipynb_content("/nonexistent_dir_no_chance/nb.ipynb", valid_ipynb)
		assert.is_false(ok)
		assert.matches("temp file", err)
	end)
end)

describe("jupytext atomic save (write_notebook end-to-end)", function()
	it("converts a percent buffer and lands valid nbformat JSON with no temp leftovers", function()
		if jupytext.find_jupytext_cli() == nil then
			return
		end

		local dir = vim.fn.tempname()
		vim.fn.mkdir(dir, "p")
		local target = dir .. "/nb.ipynb"

		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_name(bufnr, target)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"# %% [markdown]",
			"# # Title",
			"#",
			"# body",
			"",
			"# %%",
			"print(1)",
		})

		local ok = jupytext._write_notebook(bufnr, target)
		assert.is_true(ok)
		local decoded = vim.fn.json_decode(vim.fn.readfile(target))
		assert.equals(4, decoded.nbformat)
		assert.equals(0, vim.fn.filereadable(target .. ".tmp"))

		vim.api.nvim_buf_delete(bufnr, { force = true })
		vim.fn.delete(dir, "rf")
	end)
end)

describe("jupytext security", function()
	it("should not contain sh -c wrapping pattern", function()
		local source_path = "lua/pyworks/notebook/jupytext.lua"
		local lines = vim.fn.readfile(source_path)
		local source = table.concat(lines, "\n")
		assert.is_nil(source:match('"sh",%s*"-c"'), "jupytext.lua should not use sh -c wrapping")
	end)
end)
