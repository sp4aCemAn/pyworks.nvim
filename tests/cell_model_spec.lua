-- Tests for the canonical cell model (F1, docs/UX_MODEL_A_REFACTOR.md)

describe("core cell_model", function()
	local cell_model
	local cell_engine

	local function make_buf(lines)
		local bufnr = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		return bufnr
	end

	before_each(function()
		package.loaded["pyworks.core.cell_model"] = nil
		package.loaded["pyworks.core.cell_engine"] = nil
		cell_model = require("pyworks.core.cell_model")
		cell_engine = require("pyworks.core.cell_engine")
	end)

	after_each(function()
		cell_engine.configure({ cell_marker = "# %%" })
	end)

	describe("for_buffer", function()
		it("empty file yields only the (empty-content) preamble cell", function()
			local bufnr = make_buf({})
			assert.same({
				{ index = 0, marker_line = 0, type = "code", start_line = 1, end_line = 1 },
			}, cell_model.for_buffer(bufnr))
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("markerless file is the whole file as preamble cell 0", function()
			local bufnr = make_buf({ "x = 1", "y = 2" })
			assert.same({
				{ index = 0, marker_line = 0, type = "code", start_line = 1, end_line = 2 },
			}, cell_model.for_buffer(bufnr))
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("builds canonical cells with index/marker/type/ranges", function()
			local bufnr = make_buf({
				"# preamble = 1",
				"# %%",
				"x = 1",
				"y = 2",
				"# %% [markdown]",
				"# hello",
				"# %% [raw]",
				"raw text",
				"# %%",
				"z = 3",
			})
			assert.same({
				{ index = 0, marker_line = 0, type = "code", start_line = 1, end_line = 1 },
				{
					index = 1,
					marker_line = 2,
					type = "code",
					start_line = 3,
					end_line = 4,
					marker_text = "# %%",
				},
				{
					index = 2,
					marker_line = 5,
					type = "markdown",
					start_line = 6,
					end_line = 6,
					marker_text = "# %% [markdown]",
				},
				{
					index = 3,
					marker_line = 7,
					type = "raw",
					start_line = 8,
					end_line = 8,
					marker_text = "# %% [raw]",
				},
				{
					index = 4,
					marker_line = 9,
					type = "code",
					start_line = 10,
					end_line = 10,
					marker_text = "# %%",
				},
			}, cell_model.for_buffer(bufnr))
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("omits the preamble when the first marker is line 1", function()
			local bufnr = make_buf({ "# %%", "x = 1" })
			local cells = cell_model.for_buffer(bufnr)
			assert.equals(1, #cells)
			assert.equals(1, cells[1].index)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("keeps consecutive markers as (empty) cells", function()
			local bufnr = make_buf({ "# %%", "# %%", "# %%" })
			local cells = cell_model.for_buffer(bufnr)
			assert.equals(3, #cells)
			for i, cell in ipairs(cells) do
				assert.equals(i, cell.index)
				assert.equals(i, cell.marker_line)
				assert.equals(i + 1, cell.start_line)
				assert.equals(i, cell.end_line)
				assert.is_true(cell.start_line > cell.end_line, "cell " .. i .. " must be empty")
			end
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("extends the final cell to end of buffer", function()
			local bufnr = make_buf({ "# %%", "x = 1", "# %% [markdown]", "tail", "more tail" })
			local cells = cell_model.for_buffer(bufnr)
			assert.equals(2, cells[2].index)
			assert.equals("markdown", cells[2].type)
			assert.equals(4, cells[2].start_line)
			assert.equals(5, cells[2].end_line, "final cell must extend to EOF")
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("classifies trailing text and metadata on marker lines", function()
			local bufnr = make_buf({
				"# %% [markdown] Introduction",
				"a",
				'# %% {"tags": ["hide-input"]}',
				"b",
				"# %% raw",
				"c",
			})
			local cells = cell_model.for_buffer(bufnr)
			assert.equals("markdown", cells[1].type)
			assert.equals("code", cells[2].type)
			assert.equals("code", cells[3].type)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("a code-cell TITLE containing '[markdown]' stays a code cell", function()
			-- Regression: classify_marker used a bare substring match, so
			-- "# %% load [markdown] data" misclassified as markdown — and
			-- run-all (skip-by-TYPE) silently skipped executing it.
			local bufnr = make_buf({
				"# %% load [markdown] data",
				"x = 1",
			})
			local cells = cell_model.for_buffer(bufnr)
			assert.equals("code", cells[1].type)
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("honors a custom cell_marker", function()
			cell_engine.configure({ cell_marker = "# COMMAND ----------" })
			local bufnr = make_buf({
				"# COMMAND ---------- [markdown]",
				"custom md",
				"# COMMAND ----------",
				"x = 1",
			})
			assert.same({
				{
					index = 1,
					marker_line = 1,
					type = "markdown",
					start_line = 2,
					end_line = 2,
					marker_text = "# COMMAND ---------- [markdown]",
				},
				{
					index = 2,
					marker_line = 3,
					type = "code",
					start_line = 4,
					end_line = 4,
					marker_text = "# COMMAND ----------",
				},
			}, cell_model.for_buffer(bufnr))
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("returns nothing for an invalid buffer", function()
			assert.same({}, cell_model.for_buffer(999999))
		end)
	end)

	describe("markers", function()
		it("excludes the preamble and keeps order", function()
			local bufnr = make_buf({ "top = 1", "# %%", "x = 1", "# %%", "y = 2" })
			local markers = cell_model.markers(bufnr)
			assert.equals(2, #markers)
			assert.same({ 2, 4 }, { markers[1].marker_line, markers[2].marker_line })
			assert.same({ 1, 2 }, { markers[1].index, markers[2].index })
			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("cell_at", function()
		local bufnr
		after_each(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.api.nvim_buf_delete(bufnr, { force = true })
			end
		end)

		it("maps preamble, marker, and content lines to the right cells", function()
			bufnr = make_buf({
				"pre = 1",
				"# %%",
				"x = 1",
				"# %% [markdown]",
				"# hi",
			})
			assert.equals(0, cell_model.cell_at(bufnr, 1).index)
			assert.equals(1, cell_model.cell_at(bufnr, 2).index, "marker line belongs to its own cell")
			assert.equals(1, cell_model.cell_at(bufnr, 3).index)
			assert.equals(2, cell_model.cell_at(bufnr, 4).index)
			assert.equals(2, cell_model.cell_at(bufnr, 5).index)
			assert.is_nil(cell_model.cell_at(bufnr, 6))
		end)

		it("returns the cell on a trailing marker line (empty cell)", function()
			bufnr = make_buf({ "# %%", "x = 1", "# %%" })
			local cell = cell_model.cell_at(bufnr, 3)
			assert.equals(2, cell.index)
			assert.is_true(cell.start_line > cell.end_line)
		end)

		it("defaults to the cursor line of the current buffer", function()
			bufnr = make_buf({ "# %%", "x = 1", "# %%", "y = 2" })
			vim.api.nvim_set_current_buf(bufnr)
			vim.api.nvim_win_set_cursor(0, { 4, 0 })
			assert.equals(2, cell_model.cell_at().index)
		end)

		it("is nil past the buffer and on invalid buffers", function()
			bufnr = make_buf({ "# %%", "x = 1" })
			assert.is_nil(cell_model.cell_at(bufnr, 99))
			assert.is_nil(cell_model.cell_at(999999, 1))
		end)
	end)

	-- Absorbed from cell_engine_spec (S1) when the model became the region
	-- source of truth; cell_engine.get_markdown_regions now delegates here.
	describe("markdown_regions", function()
		it("should return content ranges excluding marker lines", function()
			local bufnr = make_buf({
				"# %% [markdown]",
				"Title text",
				"more text",
				"# %%",
				"x = 1",
			})

			local regions = cell_model.markdown_regions(bufnr)
			assert.equals(1, #regions)
			assert.equals(2, regions[1].start_line)
			assert.equals(3, regions[1].end_line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should extend the final markdown cell to end of buffer", function()
			local bufnr = make_buf({
				"# %%",
				"x = 1",
				"# %% [markdown]",
				"tail text",
				"more tail",
			})

			local regions = cell_model.markdown_regions(bufnr)
			assert.equals(1, #regions)
			assert.equals(4, regions[1].start_line)
			assert.equals(5, regions[1].end_line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should return multiple regions and skip empty cells", function()
			local bufnr = make_buf({
				"# %% [markdown]",
				"# %%",
				"x = 1",
				"# %% [markdown]",
				"body",
				"# %%",
				"y = 2",
			})

			local regions = cell_model.markdown_regions(bufnr)
			assert.equals(1, #regions)
			assert.equals(5, regions[1].start_line)
			assert.equals(5, regions[1].end_line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should return empty list when no markdown cells exist", function()
			local bufnr = make_buf({
				"# %%",
				"x = 1",
			})

			assert.equals(0, #cell_model.markdown_regions(bufnr))

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should ignore raw cells", function()
			local bufnr = make_buf({
				"# %% [raw]",
				"raw text",
				"# %% [markdown]",
				"md text",
			})

			local regions = cell_model.markdown_regions(bufnr)
			assert.equals(1, #regions)
			assert.equals(4, regions[1].start_line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("should honor a custom cell_marker", function()
			cell_engine.configure({ cell_marker = "# COMMAND ----------" })
			local bufnr = make_buf({
				"# COMMAND ---------- [markdown]",
				"custom md",
				"# COMMAND ----------",
				"x = 1",
			})

			local regions = cell_model.markdown_regions(bufnr)
			assert.equals(1, #regions)
			assert.equals(2, regions[1].start_line)
			assert.equals(2, regions[1].end_line)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)
	end)

	describe("for_buffer memoization", function()
		it("reuses the same cells table until the buffer changes", function()
			local bufnr = make_buf({ "# %%", "x = 1" })
			local first = cell_model.for_buffer(bufnr)
			local second = cell_model.for_buffer(bufnr)
			assert.is_true(first == second, "unchanged tick must serve the memoized table")

			-- An edit bumps changedtick: a fresh table reflecting the edit
			vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, { "# %%", "x = 1", "# %%", "y = 2" })
			local third = cell_model.for_buffer(bufnr)
			assert.equals(2, #third, "edited buffer must be re-scanned, not memoized stale")
			assert.is_false(third == first)

			vim.api.nvim_buf_delete(bufnr, { force = true })
		end)

		it("does not leak the memo across different buffers", function()
			local a = make_buf({ "# %%", "x = 1" })
			local b = make_buf({ "# %%", "y = 2", "# %%", "z = 3" })
			local cells_a = cell_model.for_buffer(a)
			local cells_b = cell_model.for_buffer(b)
			assert.equals(1, #cells_a)
			assert.equals(2, #cells_b)

			vim.api.nvim_buf_delete(a, { force = true })
			vim.api.nvim_buf_delete(b, { force = true })
		end)
	end)
end)
