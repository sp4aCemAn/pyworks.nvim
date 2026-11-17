describe("plugin/pyworks", function()
	local plugin_path = vim.fn.fnamemodify(vim.fn.getcwd(), ":p")

	before_each(function()
		vim.g.loaded_pyworks = nil
		vim.cmd("source " .. vim.fn.fnameescape(plugin_path .. "plugin/pyworks.lua"))
	end)

	describe("FileType autocmd", function()
		it("should set pyworks_filetype_setup_done after first run", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "/test.py")
			vim.api.nvim_set_current_buf(bufnr)

			vim.bo[bufnr].filetype = "python"
			vim.api.nvim_exec_autocmds("FileType", { buffer = bufnr })

			local done = vim.b[bufnr].pyworks_filetype_setup_done
			assert.is_true(done)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should not re-run setup if already done", function()
			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. "/test.py")
			vim.api.nvim_set_current_buf(bufnr)

			vim.b[bufnr].pyworks_filetype_setup_done = true

			local ok = pcall(vim.api.nvim_exec_autocmds, "FileType", { buffer = bufnr })
			assert.is_true(ok)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("LspAttach autocmd", function()
		it("should be registered in the Pyworks group", function()
			local found = vim.api.nvim_get_autocmds({ event = "LspAttach", group = "Pyworks" })
			assert.is_true(#found > 0, "plugin/pyworks.lua must register an LspAttach autocmd")
		end)

		it("should be a safe no-op for unknown client ids", function()
			assert.has_no.errors(function()
				vim.api.nvim_exec_autocmds("LspAttach", {
					buffer = vim.api.nvim_get_current_buf(),
					data = { client_id = 999999 },
				})
			end)
		end)

		it("should detach the client when a notebook buffer attaches in detach mode", function()
			package.loaded["pyworks"] = {
				get_config = function()
					return { notebooks = { lsp = "detach" } }
				end,
			}
			package.loaded["pyworks.notebook.lsp"] = nil

			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(bufnr, vim.fn.tempname() .. ".ipynb")

			local detached = {}
			local fake_client = {
				id = 99,
				detach_buffer = function(_, b)
					table.insert(detached, b)
				end,
			}
			local orig_get = vim.lsp.get_client_by_id
			vim.lsp.get_client_by_id = function(id)
				if id == 99 then
					return fake_client
				end
				return orig_get(id)
			end

			vim.api.nvim_exec_autocmds("LspAttach", { buffer = bufnr, data = { client_id = 99 } })

			vim.lsp.get_client_by_id = orig_get
			package.loaded["pyworks"] = nil
			package.loaded["pyworks.notebook.lsp"] = nil

			assert.same({ bufnr }, detached)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("PyworksReloadNotebook unsaved-edit guard", function()
		local guard

		before_each(function()
			guard = require("pyworks.core.recursion_guard")
			guard.force_reset()
			vim.g.loaded_pyworks = nil
			vim.cmd("source " .. vim.fn.fnameescape(plugin_path .. "plugin/pyworks.lua"))
		end)

		it("refuses without bang and leaves the modified buffer untouched", function()
			local dir = vim.fn.tempname()
			vim.fn.mkdir(dir, "p")
			local nb_path = dir .. "/nb.ipynb"
			vim.fn.writefile({ '{"nbformat": 4, "cells": []}' }, nb_path)

			local bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_name(bufnr, nb_path)
			vim.bo[bufnr].buftype = ""
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "unsaved edit sentinel" })
			vim.bo[bufnr].modified = true
			vim.api.nvim_set_current_buf(bufnr)

			local ok = pcall(vim.cmd, "PyworksReloadNotebook")
			assert.is_true(ok)

			assert.equals("unsaved edit sentinel", vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1])
			assert.is_true(vim.bo[bufnr].modified)

			guard.force_reset()
			vim.api.nvim_buf_delete(bufnr, { force = true })
			vim.fn.delete(dir, "rf")
		end)
	end)
end)
