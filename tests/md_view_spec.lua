-- Tests for Model A F6: inline markdown concealment (notebook/md_view.lua)

describe("notebook md_view", function()
	local md_view
	local bufnr
	local notebook_path

	local function set_cfg(notebooks)
		package.loaded["pyworks"] = {
			get_config = function()
				return { notebooks = notebooks or {} }
			end,
		}
	end

	local function make_notebook(lines)
		notebook_path = vim.fn.tempname() .. ".ipynb"
		bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_buf_set_name(bufnr, notebook_path)
		vim.b[bufnr].pyworks_notebook_path = notebook_path
		vim.api.nvim_set_current_buf(bufnr)
		return bufnr
	end

	before_each(function()
		package.loaded["pyworks"] = nil
		package.loaded["pyworks.notebook.md_view"] = nil
		package.loaded["pyworks.core.cell_engine"] = nil
		require("pyworks.core.cell_engine").configure({ cell_marker = "# %%" })
		set_cfg({ md_conceal = true, md_fold_default = false })
		md_view = require("pyworks.notebook.md_view")
		md_view.setup()
	end)

	after_each(function()
		for _, win in ipairs(vim.api.nvim_list_wins()) do
			vim.fn.clearmatches(win)
		end
		if bufnr and vim.api.nvim_buf_is_valid(bufnr) then
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end
		vim.cmd("only")
		bufnr = nil
	end)

	describe("setup", function()
		it("is idempotent and registers autocmds", function()
			assert.is_true(md_view.setup())
			assert.has_no.errors(function()
				md_view.setup()
			end)
			local found = 0
			for _, au in ipairs(vim.api.nvim_get_autocmds({ group = "PyworksMdView" })) do
				if au.desc and au.desc:match("^Pyworks:") then
					found = found + 1
				end
			end
			assert.is_true(found >= 3, "expected BufWinEnter/WinEnter, TextChanged*, WinClosed, BufDelete autocmds")
		end)
	end)

	describe("_conceal_pattern", function()
		it("uses exclusive atoms over the inclusive region bounds", function()
			make_notebook({
				"# %% [markdown]", -- 1
				"# # Title", -- 2
				"# body", -- 3
				"# %%", -- 4
				"x = 1", -- 5
			})
			assert.equals(
				"^#\\s\\?\\%>1l\\%<4l",
				md_view._conceal_pattern(bufnr),
				"region [2,3] -> ^#\\s\\?\\%>1l\\%<4l (spike: atoms after ^; \\%>= is invalid)"
			)
		end)

		it("alternates all markdown regions into one pattern", function()
			make_notebook({
				"# %% [markdown]", -- 1
				"# a", -- 2
				"# %%", -- 3
				"x = 1", -- 4
				"# %% [markdown]", -- 5
				"# b", -- 6
				"# c", -- 7
			})
			local pat = md_view._conceal_pattern(bufnr)
			assert.equals(pat, "^#\\s\\?\\%>1l\\%<3l\\|^#\\s\\?\\%>5l\\%<8l")
			-- Regression (spike): with atoms BEFORE ^, every branch after the
			-- first \| silently matched nothing. Search must reach BOTH regions.
			vim.api.nvim_win_set_cursor(0, { 1, 0 })
			assert.equals(2, (vim.fn.searchpos(pat, "ncW"))[1])
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			assert.equals(6, (vim.fn.searchpos(pat, "ncW"))[1], "second region branch must match")
		end)

		it("is nil when there are no markdown cells", function()
			make_notebook({ "# %%", "x = 1" })
			assert.is_nil(md_view._conceal_pattern(bufnr))
		end)
	end)

	describe("refresh", function()
		it("installs the conceal match and window options on notebook windows", function()
			make_notebook({ "# %% [markdown]", "# text", "# %%", "x = 1" })
			md_view.refresh(bufnr)
			local matches = vim.fn.getmatches()
			assert.equals(1, #matches)
			assert.equals("^#\\s\\?\\%>1l\\%<3l", matches[1].pattern)
			assert.equals(2, vim.wo.conceallevel)
			assert.equals("nvi", vim.wo.concealcursor)
		end)

		it("replaces (never stacks) matches on repeated refreshes", function()
			make_notebook({ "# %% [markdown]", "# text", "# %%", "x = 1" })
			md_view.refresh(bufnr)
			md_view.refresh(bufnr)
			assert.equals(1, #vim.fn.getmatches())
		end)

		it("tracks buffer edits on refresh", function()
			make_notebook({ "# %% [markdown]", "# text", "# %%", "x = 1" })
			md_view.refresh(bufnr)
			vim.api.nvim_buf_set_lines(bufnr, 0, 0, false, { "pre = 1" })
			md_view.refresh(bufnr)
			assert.equals("^#\\s\\?\\%>2l\\%<4l", vim.fn.getmatches()[1].pattern)
		end)

		it("does nothing on non-notebook buffers", function()
			bufnr = vim.api.nvim_create_buf(false, true)
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# %% [markdown]", "# text" })
			vim.api.nvim_set_current_buf(bufnr)
			md_view.refresh(bufnr)
			assert.equals(0, #vim.fn.getmatches())
		end)

		it("drops the match when notebooks.md_conceal is false", function()
			make_notebook({ "# %% [markdown]", "# text", "# %%", "x = 1" })
			md_view.refresh(bufnr)
			assert.equals(1, #vim.fn.getmatches())
			set_cfg({ md_conceal = false })
			md_view.refresh(bufnr)
			assert.equals(0, #vim.fn.getmatches())
		end)
	end)

	describe("md_fold_default", function()
		it("collapses markdown cells via level-2 folds when enabled", function()
			set_cfg({ md_conceal = true, md_fold_default = true })
			make_notebook({ "# %%", "x = 1", "# %% [markdown]", "# text", "# %%", "y = 2" })
			md_view.refresh(bufnr)
			assert.equals("expr", vim.wo.foldmethod)
			assert.equals(1, vim.wo.foldlevel, "level-1 code folds open, level-2 md folds closed")

			local cell_model = require("pyworks.core.cell_model")
			local ui = require("pyworks.ui")
			vim.v.lnum = 3 -- markdown marker -> level 2
			assert.equals(">2", ui.cell_fold_expr(), "md marker should open a deeper fold")
			vim.v.lnum = 1 -- code marker -> level 1 (cell_model sanity)
			assert.equals(">1", ui.cell_fold_expr())
			assert.is_true(cell_model.is_marker_line(bufnr, 3))
		end)

		it("keeps uniform level-1 folds when disabled (default)", function()
			make_notebook({ "# %% [markdown]", "# text" })
			local ui = require("pyworks.ui")
			vim.v.lnum = 1
			assert.equals(">1", ui.cell_fold_expr())
		end)
	end)
end)
