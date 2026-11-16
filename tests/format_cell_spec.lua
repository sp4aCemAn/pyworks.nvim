-- Tests for the markdown cell formatter command

describe("commands format_cell", function()
	local format_cell
	local fmt_paths = {}

	local function write_script(body_lines)
		local path = vim.fn.fnamemodify(vim.fn.tempname(), ":r") .. ".sh"
		local content = { "#!/bin/sh" }
		for _, line in ipairs(body_lines) do
			table.insert(content, line)
		end
		vim.fn.writefile(content, path)
		-- vim.fn.setchmod() requires the +chmod feature; shell out (repo
		-- targets POSIX only)
		vim.system({ "chmod", "755", path }):wait()
		table.insert(fmt_paths, path)
		return path
	end

	local function stub_config(formatter)
		package.loaded["pyworks"] = {
			get_config = function()
				return { notebooks = { md_formatter = formatter } }
			end,
		}
	end

	local function region_buf(lines, cursor_line)
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.api.nvim_set_current_buf(bufnr)
		vim.api.nvim_win_set_cursor(0, { cursor_line, 0 })
		return bufnr
	end

	before_each(function()
		package.loaded["pyworks"] = nil
		package.loaded["pyworks.core.cell_engine"] = nil
		package.loaded["pyworks.commands.format_cell"] = nil

		stub_config({ write_script({ "tr a-z A-Z" }) })
		format_cell = require("pyworks.commands.format_cell")
	end)

	after_each(function()
		for _, path in ipairs(fmt_paths) do
			os.remove(path)
		end
		fmt_paths = {}
	end)

	describe("_find_enclosing_md_region", function()
		it("should return content bounds for marker and content lines", function()
			local bufnr = region_buf({ "# %% [markdown]", "hello", "# %%", "x = 1" }, 2)

			local r = format_cell._find_enclosing_md_region(bufnr, 2)
			assert.equals(2, r.start_line)
			assert.equals(2, r.end_line)
			assert.same(r, format_cell._find_enclosing_md_region(bufnr, 1))
			assert.is_nil(format_cell._find_enclosing_md_region(bufnr, 4))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should extend the last cell to EOF and reject empty cells", function()
			local bufnr = region_buf({ "# %%", "x = 1", "# %% [markdown]", "tail" }, 4)
			local r = format_cell._find_enclosing_md_region(bufnr, 4)
			assert.equals(4, r.end_line)

			local empty = region_buf({ "# %% [markdown]", "# %%", "x = 1" }, 1)
			assert.is_nil(format_cell._find_enclosing_md_region(empty, 1))

			vim.api.nvim_buf_delete(bufnr, { force = true })
			vim.api.nvim_buf_delete(empty, { force = true })
		end)
	end)

	describe("format_current_cell", function()
		it("should register the user command at module load", function()
			assert.equals(2, vim.fn.exists(":PyworksFormatMarkdownCell"))
		end)

		it("should replace md content with formatter stdout", function()
			local bufnr = region_buf({ "# %% [markdown]", "hello world", "", "# %%", "x = 1" }, 2)

			local done, result = false, nil
			local ok = format_cell.format_current_cell(function(r)
				done, result = true, r
			end)
			assert.is_true(ok)
			vim.wait(5000, function()
				return done
			end)
			assert.is_true(result)

			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.same({ "# %% [markdown]", "HELLO WORLD", "", "# %%", "x = 1" }, lines)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should refuse with a hint when the formatter is missing", function()
			stub_config({ "/nonexistent/mdfmt-xyz" })
			local bufnr = region_buf({ "# %% [markdown]", "hello", "# %%", "x = 1" }, 2)

			local seen = {}
			local notify_orig = vim.notify
			vim.notify = function(msg, level)
				table.insert(seen, { msg = tostring(msg), level = level })
			end
			local ok = format_cell.format_current_cell()
			vim.notify = notify_orig

			assert.is_false(ok)
			local hinted = false
			for _, n in ipairs(seen) do
				if n.msg:match("not found") then
					hinted = true
				end
			end
			assert.is_true(hinted, "expected a 'formatter not found' notification")
			local unchanged = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			assert.same({ "# %% [markdown]", "hello", "# %%", "x = 1" }, unchanged)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should refuse on code cells and unmodifiable buffers", function()
			local code = region_buf({ "# %% [markdown]", "hi", "# %%", "x = 1" }, 4)
			assert.is_false(format_cell.format_current_cell())
			vim.api.nvim_buf_delete(code, { force = true })

			local ro = region_buf({ "# %% [markdown]", "hi" }, 2)
			vim.bo[ro].modifiable = false
			assert.is_false(format_cell.format_current_cell())
			vim.api.nvim_buf_delete(ro, { force = true })
		end)

		it("should leave the buffer untouched when the formatter fails", function()
			stub_config({ write_script({ "cat >/dev/null", "echo bad >&2", "exit 3" }) })

			local bufnr = region_buf({ "# %% [markdown]", "hello", "# %%", "x = 1" }, 2)

			local done, result = false, nil
			local ok = format_cell.format_current_cell(function(r)
				done, result = true, r
			end)
			assert.is_true(ok)
			vim.wait(5000, function()
				return done
			end)
			assert.is_false(result)
			assert.same(
				{ "# %% [markdown]", "hello", "# %%", "x = 1" },
				vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)
end)
