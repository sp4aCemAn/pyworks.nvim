describe("python command security", function()
	local python

	before_each(function()
		package.loaded["pyworks.languages.python"] = nil
		python = require("pyworks.languages.python")
	end)

	describe("shell safety", function()
		it("should not contain sh -c wrapping pattern in python.lua", function()
			local source_path = "lua/pyworks/languages/python.lua"
			local lines = vim.fn.readfile(source_path)
			local source = table.concat(lines, "\n")
			assert.is_nil(source:match('"sh",%s*"-c"'), "python.lua should not use sh -c wrapping")
		end)

		it("should not contain sh -c wrapping pattern in utils.lua", function()
			local source_path = "lua/pyworks/utils.lua"
			local lines = vim.fn.readfile(source_path)
			local source = table.concat(lines, "\n")
			assert.is_nil(source:match('"sh",%s*"-c"'), "utils.lua should not use sh -c wrapping")
		end)
	end)

	describe("pip_path nil safety", function()
		it("get_pip_path should return nil when no venv exists", function()
			local result = python.get_pip_path("/nonexistent/path/file.py")
			assert.is_nil(result)
		end)
	end)

	describe("package-name validation on exec paths", function()
		it("install_packages rejects pip option smuggling before any venv work", function()
			local dir = vim.fn.tempname()
			vim.fn.mkdir(dir, "p")

			-- Everything here is invalid: the validator must short-circuit
			-- BEFORE has_venv/create_venv, so no venv is ever created.
			local result = python.install_packages({
				"--index-url",
				"http://evil/simple",
				"extra-index-url",
			}, dir)
			assert.is_false(result)
			assert.equals(0, vim.fn.isdirectory(dir .. "/.venv"))

			vim.fn.delete(dir, "rf")
		end)

		it("uninstall path strips invalid names instead of passing them to pip", function()
			-- Direct validator coverage for the uninstall wiring
			local valid, invalid = require("pyworks.core.packages").validate_package_names({
				"requests",
				"--user",
			})
			assert.same({ "requests" }, valid)
			assert.same({ "--user" }, invalid)
		end)
	end)
end)
