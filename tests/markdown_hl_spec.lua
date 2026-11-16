-- Tests for markdown cell content highlighting in notebook buffers

describe("notebook markdown_hl", function()
	local markdown_hl

	local function make_md_buf()
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, {
			"# %% [markdown]",
			"# hello *world*",
			"body text",
			"# %%",
			"x = 1",
		})
		return bufnr
	end

	before_each(function()
		vim.cmd("syntax on")
		package.loaded["pyworks"] = nil
		package.loaded["pyworks.core.cell_engine"] = nil
		package.loaded["pyworks.notebook.markdown_hl"] = nil
		markdown_hl = require("pyworks.notebook.markdown_hl")
	end)

	describe("magic_escape", function()
		it("should make every non-alphanumeric byte literal", function()
			-- every non-alphanumeric byte (incl. spaces) becomes \<char>
			assert.equals("\\#\\ \\%\\%", markdown_hl._magic_escape("# %%"))
			assert.equals("\\#\\ COMMAND\\ \\-" .. ("\\-"):rep(9), markdown_hl._magic_escape("# COMMAND ----------"))
		end)
	end)

	describe("setup_buffer", function()
		it("should define the pyworksMdCell region in the buffer", function()
			local bufnr = make_md_buf()
			assert.is_true(markdown_hl.setup_buffer(bufnr))

			vim.api.nvim_buf_call(bufnr, function()
				local listing = vim.fn.execute("syntax list pyworksMdCell")
				assert.is_true(listing:match("pyworksMdCell") ~= nil, "region should be defined")
				assert.is_true(listing:match("markdown") ~= nil, "region should reference the markdown cluster")
			end)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should be safely re-runnable (reload path)", function()
			local bufnr = make_md_buf()
			assert.is_true(markdown_hl.setup_buffer(bufnr))
			assert.has_no.errors(function()
				markdown_hl.setup_buffer(bufnr)
			end)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should skip when notebooks.markdown_highlight is false", function()
			package.loaded["pyworks"] = {
				get_config = function()
					return { notebooks = { markdown_highlight = false } }
				end,
			}
			local bufnr = make_md_buf()
			assert.is_false(markdown_hl.setup_buffer(bufnr))
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should skip when the syntax engine is disabled", function()
			local saved = vim.g.syntax_on
			vim.g.syntax_on = nil
			local bufnr = make_md_buf()
			assert.is_false(markdown_hl.setup_buffer(bufnr))
			vim.g.syntax_on = saved
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should restyle markdown content lines but not code lines", function()
			-- filetype deliberately unset: without the pyworksMdCell region
			-- every group here would resolve to "Normal", so any non-Normal
			-- result proves the markdown cluster is active.
			local bufnr = make_md_buf()
			vim.api.nvim_set_current_buf(bufnr)
			assert.is_true(markdown_hl.setup_buffer(bufnr))
			vim.cmd("redraw")

			local function group_at(lnum)
				local id = vim.fn.synID(lnum, 2, true)
				return vim.fn.synIDattr(vim.fn.synIDtrans(id), "name")
			end

			local md_group = group_at(2)
			assert.is_true(
				md_group:match("^markdown") ~= nil or md_group == "Delimiter" or md_group:match("@markup") ~= nil,
				"md content line should be markdown-styled, got: " .. md_group
			)

			-- code cell line must not inherit the md region
			local code_group = group_at(5)
			assert.is_false(
				code_group:match("^markdown") ~= nil or code_group == "Delimiter",
				"code line picked up markdown group: " .. code_group
			)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)
