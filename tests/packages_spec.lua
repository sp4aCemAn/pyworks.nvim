-- Test suite for pyworks.core.packages module
-- Tests import detection and package mapping

local packages = require("pyworks.core.packages")

describe("packages", function()
	describe("scan_imports", function()
		it("should extract package names from simple imports", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"import os",
				"import json",
				"import numpy",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			assert.is_true(vim.tbl_contains(imports, "os"))
			assert.is_true(vim.tbl_contains(imports, "json"))
			assert.is_true(vim.tbl_contains(imports, "numpy"))

			vim.fn.delete(temp_file)
		end)

		it("should NOT extract alias names from 'import X as Y'", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"import numpy as np",
				"import pandas as pd",
				"import matplotlib.pyplot as plt",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			-- Should have the package names
			assert.is_true(vim.tbl_contains(imports, "numpy"))
			assert.is_true(vim.tbl_contains(imports, "pandas"))
			assert.is_true(vim.tbl_contains(imports, "matplotlib"))

			-- Should NOT have the aliases
			assert.is_false(vim.tbl_contains(imports, "np"))
			assert.is_false(vim.tbl_contains(imports, "pd"))
			assert.is_false(vim.tbl_contains(imports, "plt"))

			vim.fn.delete(temp_file)
		end)

		it("should handle comma-separated imports with aliases", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"import os, sys, json",
				"import numpy as np, pandas as pd",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			-- Should have the package names
			assert.is_true(vim.tbl_contains(imports, "os"))
			assert.is_true(vim.tbl_contains(imports, "sys"))
			assert.is_true(vim.tbl_contains(imports, "json"))
			assert.is_true(vim.tbl_contains(imports, "numpy"))
			assert.is_true(vim.tbl_contains(imports, "pandas"))

			-- Should NOT have the aliases
			assert.is_false(vim.tbl_contains(imports, "np"))
			assert.is_false(vim.tbl_contains(imports, "pd"))

			vim.fn.delete(temp_file)
		end)

		it("should extract package from 'from X import Y'", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"from collections import defaultdict",
				"from pathlib import Path",
				"from sklearn.model_selection import train_test_split",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			assert.is_true(vim.tbl_contains(imports, "collections"))
			assert.is_true(vim.tbl_contains(imports, "pathlib"))
			assert.is_true(vim.tbl_contains(imports, "sklearn"))

			vim.fn.delete(temp_file)
		end)

		it("should skip relative imports", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"from . import utils",
				"from .. import config",
				"from .helpers import foo",
				"import numpy",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			-- Should NOT have relative imports
			assert.is_false(vim.tbl_contains(imports, "utils"))
			assert.is_false(vim.tbl_contains(imports, "config"))
			assert.is_false(vim.tbl_contains(imports, "helpers"))

			-- Should have regular imports
			assert.is_true(vim.tbl_contains(imports, "numpy"))

			vim.fn.delete(temp_file)
		end)

		it("should skip comments", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"# import fake_package",
				"import numpy  # real import",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			assert.is_false(vim.tbl_contains(imports, "fake_package"))
			assert.is_true(vim.tbl_contains(imports, "numpy"))

			vim.fn.delete(temp_file)
		end)
	end)

	describe("map_import_to_package", function()
		it("should map common aliases to package names", function()
			assert.equals("scikit-learn", packages.map_import_to_package("sklearn", "python"))
			assert.equals("opencv-python", packages.map_import_to_package("cv2", "python"))
			assert.equals("Pillow", packages.map_import_to_package("PIL", "python"))
			assert.equals("beautifulsoup4", packages.map_import_to_package("bs4", "python"))
		end)

		it("should return same name if no mapping exists", function()
			assert.equals("numpy", packages.map_import_to_package("numpy", "python"))
			assert.equals("pandas", packages.map_import_to_package("pandas", "python"))
		end)
	end)

	describe("is_stdlib", function()
		it("should recognize standard library modules", function()
			assert.is_true(packages.is_stdlib("os", "python"))
			assert.is_true(packages.is_stdlib("sys", "python"))
			assert.is_true(packages.is_stdlib("json", "python"))
			assert.is_true(packages.is_stdlib("collections", "python"))
			assert.is_true(packages.is_stdlib("pathlib", "python"))
			assert.is_true(packages.is_stdlib("asyncio", "python"))
		end)

		it("should not recognize third-party packages as stdlib", function()
			assert.is_false(packages.is_stdlib("numpy", "python"))
			assert.is_false(packages.is_stdlib("pandas", "python"))
			assert.is_false(packages.is_stdlib("requests", "python"))
		end)
	end)

	describe("is_custom_package", function()
		it("should recognize test modules as custom", function()
			assert.is_true(packages.is_custom_package("test_utils", "python"))
			assert.is_true(packages.is_custom_package("utils_test", "python"))
			assert.is_true(packages.is_custom_package("conftest", "python"))
		end)

		it("should recognize private modules as custom", function()
			assert.is_true(packages.is_custom_package("_internal", "python"))
		end)

		it("should not flag regular packages as custom", function()
			assert.is_false(packages.is_custom_package("numpy", "python"))
			assert.is_false(packages.is_custom_package("pandas", "python"))
		end)
	end)

	describe("is_typosquat", function()
		it("flags 1-edit near-misses of known packages", function()
			assert.are.equal("requests", packages.is_typosquat("reqeusts"))
			assert.are.equal("numpy", packages.is_typosquat("numpi"))
			assert.are.equal("matplotlib", packages.is_typosquat("matplotlb"))
			assert.are.equal("pandas", packages.is_typosquat("pandas2"))
			assert.are.equal("scikit-learn", packages.is_typosquat("scikit-lern"))
		end)

		it("flags 2-edit near-misses (transpositions) for longer names", function()
			assert.are.equal("pandas", packages.is_typosquat("pnadas"))
			assert.are.equal("tqdm", packages.is_typosquat("tdqm"))
		end)

		it("uses the stricter 1-edit threshold for short names", function()
			assert.are.equal("jax", packages.is_typosquat("jaz")) -- 1 edit
			assert.are.equal("ray", packages.is_typosquat("raxy")) -- 1 edit
			assert.is_nil(packages.is_typosquat("xyz")) -- >=2 edits from any short known name
		end)

		it("passes known packages in any spelling", function()
			assert.is_nil(packages.is_typosquat("numpy"))
			assert.is_nil(packages.is_typosquat("SciKit-Learn"))
			assert.is_nil(packages.is_typosquat("opencv_python"))
			assert.is_nil(packages.is_typosquat("jupytext")) -- real neighbor of jupyter
			assert.is_nil(packages.is_typosquat("httpie")) -- real neighbor of httpx
		end)

		it("passes unknown-but-distant names", function()
			assert.is_nil(packages.is_typosquat("zebrafish"))
			assert.is_nil(packages.is_typosquat("fork"))
		end)

		it("flags prefix-squats of known packages regardless of edit distance", function()
			-- "scikit" ties between scikit-learn/scikit-image (same length),
			-- so accept either canonical match
			assert.is_true(
				packages.is_typosquat("scikit") == "scikit-learn" or packages.is_typosquat("scikit") == "scikit-image"
			)
			assert.are.equal("pandas", packages.is_typosquat("panda"))
			assert.are.equal("matplotlib", packages.is_typosquat("matplot"))
			assert.are.equal("torchvision", packages.is_typosquat("torchvisio"))
		end)

		it("does not prefix-flag known packages or short candidates", function()
			assert.is_nil(packages.is_typosquat("jupyter")) -- known, though prefix of jupyterlab
			assert.is_nil(packages.is_typosquat("vex")) -- ≥2 edits from any short known name (tox/jax/ray)
			-- "fast" ties at 2 edits between flask, dash, AND dask; hash
			-- iteration order picks the winner, so accept any of them
			-- (precedent: "scikit"). Blocking is correct in all cases.
			local closest = packages.is_typosquat("fast")
			assert.is_true(
				closest == "flask" or closest == "dash" or closest == "dask",
				"expected flask/dash/dask, got " .. tostring(closest)
			)
			assert.is_nil(packages.is_typosquat("dask")) -- known
		end)

		it("strips version specifiers and extras before matching", function()
			assert.are.equal("numpy", packages.is_typosquat("numpi>=1.24"))
			assert.is_nil(packages.is_typosquat("numpy[extra]==2.0"))
		end)
	end)

	describe("filter_typosquats", function()
		it("splits safe and blocked names", function()
			local safe, blocked = packages.filter_typosquats({ "requests", "reqeusts", "pandas", "zebrafish" })
			assert.are.same({ "requests", "pandas", "zebrafish" }, safe)
			assert.are.equal("requests", blocked["reqeusts"])
			assert.is_nil(blocked["requests"])
		end)
	end)

	describe("dotted namespace imports", function()
		it("keeps known multi-segment prefixes instead of confusion-bait roots", function()
			local temp_file = vim.fn.tempname() .. ".py"
			vim.fn.writefile({
				"from google.cloud import storage",
				"from google.oauth2 import service_account",
				"import os.path",
			}, temp_file)

			local imports = packages.scan_imports(temp_file, "python")

			assert.is_true(vim.tbl_contains(imports, "google.cloud"))
			assert.is_true(vim.tbl_contains(imports, "google.oauth2"))
			assert.is_false(vim.tbl_contains(imports, "google"))
			assert.is_true(vim.tbl_contains(imports, "os")) -- stdlib roots unaffected

			vim.fn.delete(temp_file)
		end)
	end)
end)
