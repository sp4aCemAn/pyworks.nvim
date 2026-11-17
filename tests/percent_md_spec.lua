-- Tests for the percent-format markdown comment codec (F2)

describe("notebook percent_md", function()
	local percent_md

	before_each(function()
		package.loaded["pyworks.notebook.percent_md"] = nil
		percent_md = require("pyworks.notebook.percent_md")
	end)

	describe("comment", function()
		it("matches jupytext examples from the verified facts", function()
			assert.same(
				{ "# text", "#", "# # h1", "#   indented" },
				percent_md.comment({ "text", "", "# h1", "  indented" })
			)
		end)

		it("returns an empty list for empty input", function()
			assert.same({}, percent_md.comment({}))
		end)
	end)

	describe("uncomment", function()
		it("matches jupytext examples from the verified facts", function()
			assert.same(
				{ "text", "", " two spaces", "# h1c", "raw" },
				percent_md.uncomment({ "# text", "#", "#  two spaces", "## h1c", "raw" })
			)
		end)

		it("leaves raw (non-comment) lines unchanged", function()
			-- "#!" starts with the comment char, so (per jupytext) it sheds
			-- the leading "#"; lines without a leading "#" pass through.
			assert.same(
				{ "x = 1", "", "!", "print('raw')" },
				percent_md.uncomment({ "x = 1", "", "#!", "print('raw')" })
			)
		end)

		it("returns an empty list for empty input", function()
			assert.same({}, percent_md.uncomment({}))
		end)
	end)

	describe("round-trip property", function()
		it("uncomment(comment(md)) is the identity on real markdown", function()
			local md_samples = {
				{ "text" },
				{ "" },
				{ "# h1", "body" },
				{ "  indented", "\tTabbed" },
				{ "#", "# # deep", "#has no space" },
				{ "trailing spaces  ", "  " },
				{ "unicode ✨ ünïcödé" },
			}
			for _, lines in ipairs(md_samples) do
				assert.same(lines, percent_md.uncomment(percent_md.comment(lines)), table.concat(lines, "|"))
			end
		end)

		it("comment(uncomment(buffer)) is the identity on canonical lines", function()
			local canonical_samples = {
				{ "# text", "#", "# # h1" },
				{ "#   indented" },
				{ "# ## h2" },
				{},
			}
			for _, lines in ipairs(canonical_samples) do
				assert.same(lines, percent_md.comment(percent_md.uncomment(lines)))
			end
		end)

		it("'## h1' stays stable across a full comment round-trip", function()
			local buffer_line = "# ## h1"
			assert.equals(buffer_line, percent_md.comment(percent_md.uncomment({ buffer_line }))[1])
			assert.equals("## h1", percent_md.uncomment({ buffer_line })[1])
			assert.equals("# ## h1", percent_md.comment({ "## h1" })[1])
		end)

		it("property-checks a randomized corpus", function()
			math.randomseed(os.time())
			local chars = { "a", " ", "#", "  ", "", "x", "é" }
			for _ = 1, 200 do
				local n = math.random(0, 6)
				local lines = {}
				for _ = 1, n do
					table.insert(lines, chars[math.random(1, #chars)])
				end
				local commented = percent_md.comment(lines)
				assert.same(lines, percent_md.uncomment(commented))
				assert.same(commented, percent_md.comment(percent_md.uncomment(commented)))
			end
		end)
	end)

	-- Golden comparison against the real codec. Runs only when a jupytext
	-- executable exists (the test container has 1.19.3; host/macOS typically
	-- does not) — see docs/UX_MODEL_A_REFACTOR.md F2.
	if vim.fn.executable("jupytext") == 1 then
		describe("jupytext golden", function()
			it("uncomment matches jupytext's own markdown round-trip", function()
				local md_lines = { "# Heading", "body text", "", "  indented", "## h2" }
				-- nbformat multiline source: every line carries a trailing \n
				-- EXCEPT the last (a final \n would mean a phantom empty line).
				local function to_source(lines)
					local out = {}
					for i, line in ipairs(lines) do
						out[i] = (i < #lines) and (line .. "\n") or line
					end
					return out
				end
				local nb = vim.json.encode({
					cells = {
						{
							cell_type = "markdown",
							id = "mdcell01",
							metadata = vim.empty_dict(),
							source = to_source(md_lines),
						},
					},
					metadata = vim.empty_dict(),
					nbformat = 4,
					nbformat_minor = 5,
				})
				local ipynb = vim.fn.tempname() .. ".ipynb"
				vim.fn.writefile({ nb }, ipynb)
				local out = vim.system({ "jupytext", "--to", "py:percent", "--output", "-", ipynb }, { text = true })
					:wait()
				assert.equals(0, out.code, out.stderr)

				local buffer_md = {}
				local in_md = false
				for _, line in ipairs(vim.split(out.stdout, "\n")) do
					if line:match("^# %%") then
						in_md = line:match("%[markdown%]") ~= nil
					elseif in_md then
						table.insert(buffer_md, line)
					end
				end
				while #buffer_md > 0 and buffer_md[#buffer_md] == "" do
					table.remove(buffer_md)
				end

				assert.same(percent_md.comment(md_lines), buffer_md)
				assert.same(md_lines, percent_md.uncomment(buffer_md))
				os.remove(ipynb)
			end)
		end)
	end
end)
