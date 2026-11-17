-- Universal package detection and management for pyworks.nvim

local M = {}

local cache = require("pyworks.core.cache")
local notifications = require("pyworks.core.notifications")

-- Maximum file size to scan for imports (1MB) - prevents blocking on large files
local MAX_FILE_SIZE_BYTES = 1024 * 1024

-- Default custom package prefixes (can be extended via configure())
local config = {
	custom_package_prefixes = {
		"^my_",
		"^custom_",
		"^local_",
		"^internal_",
		"^private_",
		"^app_",
		"^lib_",
		"^src$",
		"^utils$",
		"^helpers$",
	},
}

function M.configure(opts)
	config = vim.tbl_deep_extend("force", config, opts or {})
end

-- Package name mappings for common mismatches (import name -> PyPI package name)
-- Updated for 2025 with AI/ML packages
local package_mappings = {
	python = {
		-- Data Science & ML classics
		["sklearn"] = "scikit-learn",
		["cv2"] = "opencv-python",
		["cv"] = "opencv-python",
		["PIL"] = "Pillow",
		["bs4"] = "beautifulsoup4",
		["sns"] = "seaborn",
		["yaml"] = "PyYAML",
		["skimage"] = "scikit-image",

		-- AI/ML frameworks (2025)
		["torch"] = "torch",
		["torchvision"] = "torchvision",
		["torchaudio"] = "torchaudio",
		["tensorflow"] = "tensorflow",
		["tf"] = "tensorflow",
		["keras"] = "keras",
		["jax"] = "jax",
		["flax"] = "flax",

		-- LLM & AI APIs (2025)
		["anthropic"] = "anthropic",
		["openai"] = "openai",
		["tiktoken"] = "tiktoken",
		["google.generativeai"] = "google-generativeai",
		["vertexai"] = "google-cloud-aiplatform",
		["cohere"] = "cohere",
		["replicate"] = "replicate",
		["groq"] = "groq",
		["mistralai"] = "mistralai",

		-- LangChain ecosystem
		["langchain"] = "langchain",
		["langchain_core"] = "langchain-core",
		["langchain_community"] = "langchain-community",
		["langchain_openai"] = "langchain-openai",
		["langchain_anthropic"] = "langchain-anthropic",
		["langgraph"] = "langgraph",
		["langsmith"] = "langsmith",

		-- Vector databases & embeddings
		["faiss"] = "faiss-cpu",
		["chromadb"] = "chromadb",
		["pinecone"] = "pinecone-client",
		["qdrant_client"] = "qdrant-client",
		["weaviate"] = "weaviate-client",
		["lancedb"] = "lancedb",
		["milvus"] = "pymilvus",

		-- Transformers & NLP
		["transformers"] = "transformers",
		["sentence_transformers"] = "sentence-transformers",
		["datasets"] = "datasets",
		["tokenizers"] = "tokenizers",
		["accelerate"] = "accelerate",
		["peft"] = "peft",
		["trl"] = "trl",
		["spacy"] = "spacy",
		["nltk"] = "nltk",

		-- Web & API frameworks
		["discord"] = "discord.py",
		["dotenv"] = "python-dotenv",
		["rest_framework"] = "djangorestframework",
		["fastapi"] = "fastapi",
		["starlette"] = "starlette",
		["pydantic"] = "pydantic",
		["httpx"] = "httpx",
		["aiohttp"] = "aiohttp",

		-- Database & ORM
		["sqlalchemy"] = "sqlalchemy",
		["sqlmodel"] = "sqlmodel",
		["alembic"] = "alembic",
		["psycopg2"] = "psycopg2-binary",
		["psycopg"] = "psycopg",
		["asyncpg"] = "asyncpg",
		["pymongo"] = "pymongo",
		["redis"] = "redis",

		-- Utilities
		["magic"] = "python-magic",
		["dateutil"] = "python-dateutil",
		["jwt"] = "PyJWT",
		["OpenSSL"] = "pyOpenSSL",
		["serial"] = "pyserial",
		["usb"] = "pyusb",
		["Crypto"] = "pycryptodome",
		["cryptography"] = "cryptography",
		["websocket"] = "websocket-client",
		["websockets"] = "websockets",

		-- Google Cloud
		["google.cloud"] = "google-cloud-storage",
		["google.auth"] = "google-auth",
		["google.oauth2"] = "google-auth-oauthlib",

		-- GUI & system
		["wx"] = "wxPython",
		["gi"] = "PyGObject",
		["dbus"] = "dbus-python",
		["apt"] = "python-apt",
		["cairo"] = "pycairo",

		-- Testing
		["pytest"] = "pytest",
		["hypothesis"] = "hypothesis",
		["faker"] = "faker",
		["factory"] = "factory-boy",

		-- CLI & config
		["typer"] = "typer",
		["click"] = "click",
		["rich"] = "rich",
		["tqdm"] = "tqdm",
	},
}

-- Generate reverse mappings (package name -> import name) at module load
local reverse_package_mappings = {}
for lang, mappings in pairs(package_mappings) do
	reverse_package_mappings[lang] = {}
	for import_name, pkg_name in pairs(mappings) do
		reverse_package_mappings[lang][pkg_name:lower()] = import_name
	end
end

-- ---------------------------------------------------------------------------
-- Typosquat detection (supply-chain guard)
--
-- Import names lifted from (potentially untrusted) file content fall through
-- map_import_to_package() verbatim when unmapped. Without this guard, a shared
-- notebook containing `import reqeusts` or `import numpi` would get squatted
-- packages auto-installed on one keystroke (<leader>pi), executing attacker
-- setup.py code in the user's venv.
--
-- known_packages is SECURITY-CRITICAL: grow it via PR review when common new
-- libraries keep getting flagged. A candidate passes if it matches a known
-- name exactly (after PEP 503 normalization); a near-match (bounded Levenshtein)
-- is flagged. Homoglyph/unicode lookalikes never reach the distance check:
-- is_valid_package_name() rejects non-ASCII earlier.
-- ---------------------------------------------------------------------------

local popular_packages = {
	"numpy",
	"pandas",
	"scipy",
	"matplotlib",
	"seaborn",
	"plotly",
	"altair",
	"bokeh",
	"holoviews",
	"requests",
	"urllib3",
	"httpx",
	"httpie",
	"aiohttp",
	"flask",
	"django",
	"fastapi",
	"starlette",
	"pydantic",
	"uvicorn",
	"gunicorn",
	"jinja2",
	"click",
	"typer",
	"rich",
	"tqdm",
	"python-dotenv",
	"pyyaml",
	"toml",
	"tomli",
	"attrs",
	"cattrs",
	"marshmallow",
	"tenacity",
	"apscheduler",
	"celery",
	"redis",
	"pymongo",
	"psycopg2-binary",
	"psycopg",
	"asyncpg",
	"sqlalchemy",
	"alembic",
	"duckdb",
	"pyarrow",
	"polars",
	"dask",
	"ray",
	"joblib",
	"statsmodels",
	"networkx",
	"sympy",
	"numba",
	"cython",
	"pytest",
	"hypothesis",
	"tox",
	"coverage",
	"black",
	"ruff",
	"flake8",
	"pylint",
	"mypy",
	"isort",
	"ipython",
	"ipykernel",
	"jupyter",
	"jupyterlab",
	"notebook",
	"nbformat",
	"jupytext",
	"transformers",
	"diffusers",
	"accelerate",
	"peft",
	"trl",
	"datasets",
	"tokenizers",
	"sentence-transformers",
	"spacy",
	"nltk",
	"gensim",
	"torch",
	"torchvision",
	"torchaudio",
	"tensorflow",
	"keras",
	"jax",
	"flax",
	"optax",
	"xgboost",
	"lightgbm",
	"catboost",
	"scikit-image",
	"opencv-python",
	"pillow",
	"imageio",
	"boto3",
	"botocore",
	"paramiko",
	"fabric",
	"invoke",
	"websocket-client",
	"websockets",
	"beautifulsoup4",
	"lxml",
	"html5lib",
	"scrapy",
	"selenium",
	"playwright",
	"openai",
	"anthropic",
	"cohere",
	"langchain",
	"langsmith",
	"langgraph",
	"tiktoken",
	"chromadb",
	"faiss-cpu",
	"pinecone-client",
	"qdrant-client",
	"weaviate-client",
	"lancedb",
	"pymilvus",
	"streamlit",
	"gradio",
	"dash",
	"uvloop",
	"trio",
	"gevent",
	"greenlet",
	"protobuf",
	"grpcio",
}

-- PEP 503-ish canonicalization: lowercase, collapse [-._]+ runs to a single "-"
local function normalize_package_name(name)
	local n = tostring(name):lower()
	n = n:gsub("[-_.]+", "-")
	return n
end

-- Bounded Levenshtein: returns distance if <= max_dist, else max_dist + 1.
local function edit_distance_at_most(a, b, max_dist)
	if math.abs(#a - #b) > max_dist then
		return max_dist + 1
	end
	local prev, curr = {}, {}
	for j = 0, #b do
		prev[j] = j
	end
	for i = 1, #a do
		curr[0] = i
		local row_min = curr[0]
		for j = 1, #b do
			local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
			curr[j] = math.min(prev[j] + 1, curr[j - 1] + 1, prev[j - 1] + cost)
			if curr[j] < row_min then
				row_min = curr[j]
			end
		end
		if row_min > max_dist then
			return max_dist + 1
		end
		prev, curr = curr, {}
	end
	return prev[#b]
end

-- normalized name -> canonical display name
local known_packages = {}
do
	for _, pkg_name in pairs(package_mappings.python) do
		known_packages[normalize_package_name(pkg_name)] = pkg_name
	end
	for _, pkg_name in ipairs(popular_packages) do
		known_packages[normalize_package_name(pkg_name)] = pkg_name
	end
end

-- Multi-segment import prefixes known to the mapping table (e.g. google.cloud).
-- Extracted imports keep the longest known dotted prefix instead of truncating
-- to the root ("google"), which would dependency-confuse into unrelated packages.
local dotted_import_prefixes = {}
do
	for import_name in pairs(package_mappings.python) do
		if import_name:find("%.") then
			dotted_import_prefixes[import_name] = true
			-- also register shortened prefixes: "google.cloud.storage" -> "google.cloud"
			for prefix in import_name:gmatch("([%w_]+%.[%w_]+)") do
				dotted_import_prefixes[prefix] = true
			end
		end
	end
end

-- Check whether a candidate package name is a near-match (possible typosquat)
-- of a known popular package.
-- Returns closest_canonical_name, distance when suspicious; nil when safe.
-- Safe by construction: exact known names (any case/separator spelling), names
-- too short/long to plausibly squat, and names farther than the threshold.
function M.is_typosquat(package_name)
	vim.validate({ package_name = { package_name, "string" } })

	-- Strip extras and version specifiers: "numpy>=1.24[extra]" -> "numpy"
	local base = package_name:match("^[%w_%-%.]+")
	if not base or base == "" then
		return nil
	end
	local norm = normalize_package_name(base)
	if known_packages[norm] then
		return nil
	end

	-- Prefix-squat rule: "scikit" (of scikit-learn), "panda" (of pandas),
	-- "matplot" (of matplotlib) are classic squat registrations and are too
	-- far in edit distance for the threshold below. Candidates that are a
	-- proper prefix of a known package (>=5 chars) are flagged; closest =
	-- shortest such known name, ties broken lexicographically so the
	-- reported canonical name is stable across processes (pairs() hash
	-- order is not).
	if #norm >= 5 then
		local best_name, best_len = nil, nil
		for known_norm, canonical in pairs(known_packages) do
			if #known_norm > #norm and known_norm:sub(1, #norm) == norm then
				if not best_len or #known_norm < best_len or (#known_norm == best_len and canonical < best_name) then
					best_len, best_name = #known_norm, canonical
				end
			end
		end
		if best_name then
			return best_name, best_len - #norm
		end
	end

	-- Threshold: 1 edit for tiny names, 2 otherwise. The distance bound
	-- stays at min(max_dist, best_dist) so equal-distance candidates are
	-- still measured — ties are broken lexicographically for determinism.
	local max_dist = #norm <= 3 and 1 or 2
	local best_name, best_dist = nil, max_dist + 1
	for known_norm, canonical in pairs(known_packages) do
		local d = edit_distance_at_most(norm, known_norm, math.min(max_dist, best_dist))
		if d < best_dist or (d == best_dist and d <= max_dist and canonical < best_name) then
			best_dist, best_name = d, canonical
		end
	end
	if best_name then
		return best_name, best_dist
	end
	return nil
end

-- Split a candidate list into (safe list, blocked map name->closest).
function M.filter_typosquats(packages)
	vim.validate({ packages = { packages, "table" } })
	local safe, blocked = {}, {}
	for _, pkg in ipairs(packages) do
		local closest = M.is_typosquat(pkg)
		if closest then
			blocked[pkg] = closest
		else
			table.insert(safe, pkg)
		end
	end
	return safe, blocked
end

-- Python standard library modules (defined at module level for performance)
-- Updated for Python 3.9+ (includes modules added in 3.9, 3.10, 3.11)
local python_stdlib = {
	-- Core
	os = true,
	sys = true,
	re = true,
	json = true,
	math = true,
	random = true,
	datetime = true,
	time = true,
	-- Collections & iterators
	collections = true,
	itertools = true,
	functools = true,
	operator = true,
	-- File system
	pathlib = true,
	shutil = true,
	glob = true,
	fnmatch = true,
	tempfile = true,
	fileinput = true,
	stat = true,
	filecmp = true,
	-- Concurrency
	subprocess = true,
	threading = true,
	multiprocessing = true,
	queue = true,
	asyncio = true,
	concurrent = true,
	contextvars = true,
	sched = true,
	-- Networking
	socket = true,
	http = true,
	urllib = true,
	email = true,
	html = true,
	xml = true,
	ftplib = true,
	poplib = true,
	imaplib = true,
	smtplib = true,
	ssl = true,
	select = true,
	selectors = true,
	socketserver = true,
	xmlrpc = true,
	ipaddress = true,
	-- Data formats
	csv = true,
	tomllib = true, -- Python 3.11+ (TOML parsing)
	configparser = true,
	netrc = true,
	plistlib = true,
	-- I/O
	io = true,
	string = true,
	codecs = true,
	textwrap = true,
	difflib = true,
	readline = true,
	rlcompleter = true,
	-- Type system
	typing = true,
	types = true,
	enum = true,
	dataclasses = true,
	abc = true,
	-- Data structures (Python 3.9+)
	graphlib = true, -- Python 3.9+ (topological sorting)
	zoneinfo = true, -- Python 3.9+ (timezone support)
	-- Object handling
	copy = true,
	pprint = true,
	reprlib = true,
	-- Persistence
	pickle = true,
	shelve = true,
	dbm = true,
	sqlite3 = true,
	-- Compression
	zlib = true,
	gzip = true,
	bz2 = true,
	lzma = true,
	zipfile = true,
	tarfile = true,
	-- Cryptography
	hashlib = true,
	hmac = true,
	secrets = true,
	-- Identifiers
	uuid = true,
	base64 = true,
	binascii = true,
	quopri = true,
	-- CLI & config
	argparse = true,
	logging = true,
	getopt = true,
	getpass = true,
	curses = true,
	-- Introspection & debugging
	inspect = true,
	traceback = true,
	warnings = true,
	contextlib = true,
	dis = true,
	linecache = true,
	-- Testing
	unittest = true,
	doctest = true,
	pdb = true,
	profile = true,
	timeit = true,
	trace = true,
	cProfile = true,
	-- Import system
	importlib = true,
	pkgutil = true,
	runpy = true,
	zipimport = true,
	-- System
	platform = true,
	errno = true,
	ctypes = true,
	struct = true,
	mmap = true,
	signal = true,
	sysconfig = true,
	-- Internationalization
	unicodedata = true,
	locale = true,
	gettext = true,
	-- Math & numbers
	statistics = true,
	decimal = true,
	fractions = true,
	numbers = true,
	cmath = true,
	-- Low-level
	array = true,
	weakref = true,
	gc = true,
	atexit = true,
	builtins = true,
	faulthandler = true,
	-- Special
	["__future__"] = true,
	["_thread"] = true,
}

-- Map import to package name
function M.map_import_to_package(import_name, language)
	language = language or "python"
	local mappings = package_mappings[language] or {}
	return mappings[import_name] or import_name
end

-- Map package name back to import name (for checking if installed)
function M.map_package_to_import(package_name, language)
	language = language or "python"
	local mappings = reverse_package_mappings[language] or {}
	return mappings[package_name:lower()] or package_name
end

-- Map a list of package names, applying known mappings (e.g., sklearn -> scikit-learn)
-- Returns mapped list and a table of any mappings that were applied
function M.map_packages(pkg_list, language)
	language = language or "python"
	local mapped = {}
	local applied_mappings = {}

	for _, pkg in ipairs(pkg_list) do
		local mapped_pkg = M.map_import_to_package(pkg, language)
		if mapped_pkg ~= pkg then
			applied_mappings[pkg] = mapped_pkg
		end
		table.insert(mapped, mapped_pkg)
	end

	return mapped, applied_mappings
end

-- Extract imports from Python file
-- Handles single-line, multiline (parenthesized), and multiple comma-separated imports
local function extract_python_imports(content)
	local imports = {}

	-- Helper to add import root package
	local function add_import(pkg)
		if pkg and pkg ~= "" then
			-- Known multi-segment imports keep their dotted prefix so mapping
			-- can resolve them ("google.cloud.storage" -> google.cloud ->
			-- google-cloud-storage) instead of installing confusion-bait roots
			-- like bare "google".
			if pkg:find("%.") then
				if dotted_import_prefixes[pkg] then
					imports[pkg] = true
					return
				end
				local two = pkg:match("^([%w_]+%.[%w_]+)")
				if two and dotted_import_prefixes[two] then
					imports[two] = true
					return
				end
			end
			-- Take only the root package (before first dot)
			local root = pkg:match("^([%w_]+)")
			if root then
				imports[root] = true
			end
		end
	end

	-- Normalize multiline imports to single-line (chained gsub for efficiency)
	-- Pass 1: "from X import (\n  a,\n  b\n)" -> "from X import multiline_placeholder"
	-- Pass 2: "import (\n  a,\n  b\n)" -> "import a, b"
	local normalized = content
		:gsub("from%s+([%w_%.]+)%s+import%s*%(([^%)]+)%)", function(pkg, _)
			return "from " .. pkg .. " import multiline_placeholder"
		end)
		:gsub("import%s*%(([^%)]+)%)", function(inner)
			local pkgs = {}
			for pkg in inner:gmatch("([%w_%.]+)") do
				if pkg ~= "as" then
					table.insert(pkgs, pkg)
				end
			end
			return "import " .. table.concat(pkgs, ", ")
		end)

	-- Strip trailing/inline comments per line BEFORE import matching.
	-- Without this, comment words inside a parenthesized multiline import
	-- ("use the fast one") get extracted as import names — "comment" is a
	-- real PyPI package, making this a live supply-chain suggestion.
	local comment_stripped = {}
	for line in normalized:gmatch("[^\r\n]+") do
		-- Truncate at a # that is not inside a string literal is overkill
		-- for import lines (imports rarely contain "#"); a simple split is
		-- safe for the import-detection use case and avoids false imports.
		table.insert(comment_stripped, (line:gsub("#.*$", "")))
	end
	normalized = table.concat(comment_stripped, "\n")

	-- Process line by line
	for line in normalized:gmatch("[^\r\n]+") do
		-- Skip comments and empty lines
		local trimmed = line:match("^%s*(.-)%s*$")
		if trimmed and trimmed ~= "" and not trimmed:match("^#") then
			-- Skip relative imports (from . import or from .. import)
			if not trimmed:match("^from%s+%.+%s+import") then
				-- Match: import package, import package as alias, import pkg1, pkg2
				local import_part = trimmed:match("^import%s+(.+)")
				if import_part then
					-- Split by comma for multiple imports
					for segment in import_part:gmatch("[^,]+") do
						-- Get only the package name (before 'as' if present)
						-- "numpy as np" -> "numpy", "pandas" -> "pandas"
						local pkg = segment:match("^%s*([%w_%.]+)")
						if pkg then
							add_import(pkg)
						end
					end
				end

				-- Match: from package import ...
				local pkg = trimmed:match("^from%s+([%w_%.]+)%s+import")
				if pkg then
					add_import(pkg)
				end
			end
		end
	end

	return vim.tbl_keys(imports)
end

-- Scan file for imports
function M.scan_imports(filepath, language)
	-- Validate inputs
	if not filepath or filepath == "" then
		return {}
	end

	-- Ensure we have an absolute path for consistent caching
	if not filepath:match("^/") then
		filepath = vim.fn.fnamemodify(filepath, ":p")
	end

	-- Try cache first
	local cache_key = "imports_" .. filepath .. "_" .. language
	local cached = cache.get(cache_key)
	if cached then
		return cached
	end

	-- Read content (from buffer for notebooks, from file for others)
	local content

	-- For notebooks (.ipynb), read from buffer instead of file
	-- because jupytext has already converted it to code
	if filepath:match("%.ipynb$") then
		-- Find buffer with this file
		local bufnr = vim.fn.bufnr(filepath)
		if bufnr ~= -1 and vim.api.nvim_buf_is_loaded(bufnr) then
			-- Read from buffer (converted content)
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			content = table.concat(lines, "\n")
		else
			-- Fallback: try to read current buffer if it's the notebook
			local current_file = vim.api.nvim_buf_get_name(0)
			if current_file == filepath then
				local lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
				content = table.concat(lines, "\n")
			else
				-- Can't read notebook content
				return {}
			end
		end
	else
		-- Regular files: read from disk
		-- Check file size first to avoid blocking on large files
		local stat = vim.uv.fs_stat(filepath)
		if not stat then
			return {}
		end
		if stat.size > MAX_FILE_SIZE_BYTES then
			notifications.notify(
				string.format("Skipping large file for import scan: %s (%.1f MB)", filepath, stat.size / 1024 / 1024),
				vim.log.levels.DEBUG
			)
			return {}
		end

		local file = io.open(filepath, "r")
		if not file then
			return {}
		end
		content = file:read("*all")
		file:close()
	end

	-- Extract imports (Python only)
	local imports = {}
	if language == "python" then
		imports = extract_python_imports(content)
	end

	-- Cache the result
	cache.set(cache_key, imports)

	return imports
end

-- Get installed packages for a language (async: the callback receives the
-- installed list; cache hits resolve synchronously)
function M.get_installed_packages(language, filepath, callback)
	-- Key the cache per PROJECT (every file in one venv shares the same
	-- installed list) instead of per file, so a whole project shares one
	-- entry instead of duplicating one per file.
	local project_root = require("pyworks.utils").get_project_paths(filepath)
	local cache_key = "installed_packages_" .. language .. "_" .. (project_root or "global")
	local cached = cache.get(cache_key)
	if cached then
		callback(cached)
		return
	end

	if language == "python" then
		local python = require("pyworks.languages.python")
		python.get_installed_packages(filepath, function(installed)
			cache.set(cache_key, installed)
			callback(installed)
		end)
		return
	end

	callback({})
end

-- Detect missing packages (async; the callback receives the missing list)
function M.detect_missing_packages(filepath, language, callback)
	local imports = M.scan_imports(filepath, language)
	M.get_installed_packages(language, filepath, function(installed)
		-- Convert installed list to a set for faster lookup
		local installed_set = {}
		for _, pkg in ipairs(installed) do
			installed_set[pkg:lower()] = true
		end

		local missing = {}
		for _, import_name in ipairs(imports) do
			-- Skip standard library modules and custom/local packages
			if not M.is_stdlib(import_name, language) and not M.is_custom_package(import_name, language) then
				-- Map import name to package name
				local package_name = M.map_import_to_package(import_name, language)

				-- Check if installed
				if not installed_set[package_name:lower()] then
					table.insert(missing, package_name)
				end
			end
		end

		callback(missing)
	end)
end

-- Check if a module is likely a custom/local package
function M.is_custom_package(module_name, language)
	if language == "python" then
		-- Skip nil or empty
		if not module_name or module_name == "" then
			return true
		end

		-- Single underscore prefix indicates internal/private module
		if module_name:match("^_[^_]") then
			return true
		end

		-- Test-related modules (pytest, unittest discovery)
		if
			module_name:match("^test_")
			or module_name:match("_test$")
			or module_name == "conftest"
			or module_name == "tests"
		then
			return true
		end

		-- Configurable custom/local package prefixes
		for _, pattern in ipairs(config.custom_package_prefixes) do
			if module_name:match(pattern) then
				return true
			end
		end

		-- Common local module names
		if module_name == "config" or module_name == "settings" then
			return true
		end

		-- Build/setup modules (not installable)
		if
			module_name == "setup"
			or module_name == "setuptools"
			or module_name == "build"
			or module_name == "noxfile"
			or module_name == "fabfile"
			or module_name == "tasks"
		then
			return true
		end
	end
	return false
end

-- Check if a module is part of standard library
function M.is_stdlib(module_name, language)
	if language == "python" then
		return python_stdlib[module_name] == true
	end
	return false
end

-- Validate package name for safety (prevents pip option injection and
-- argument smuggling; all exec is array-form vim.system, so classic shell
-- injection is not in play — but a name like "--index-url" would still be
-- parsed by pip as an OPTION).
-- Plain names: letters/digits, then _ . - [ ] (extras syntax).
-- Optional PEP 440-ish specifier: comparison ops followed by digits/dots.
local BODY = "[a-zA-Z0-9_][a-zA-Z0-9_.%-]*"
local EXTRAS = "%[[a-zA-Z0-9_.,%-]*%]"
local PACKAGE_PATTERNS = {
	"^" .. BODY .. "$",
	"^" .. BODY .. EXTRAS .. "$",
	"^" .. BODY .. EXTRAS .. "[<>=!~]+[0-9.]+$",
	"^" .. BODY .. "[<>=!~]+[0-9.]+$",
}
local function is_valid_package_name(name)
	if not name or name == "" then
		return false
	end
	for _, pattern in ipairs(PACKAGE_PATTERNS) do
		if name:find(pattern) then
			return true
		end
	end
	return false
end

-- Filter packages to only valid names
function M.validate_package_names(packages)
	local valid = {}
	local invalid = {}
	for _, pkg in ipairs(packages) do
		if is_valid_package_name(pkg) then
			table.insert(valid, pkg)
		else
			table.insert(invalid, pkg)
		end
	end
	return valid, invalid
end

-- Re-scan imports after file save (async internally; results notify)
function M.rescan_for_language(filepath, language)
	-- Invalidate cache
	cache.invalidate("imports_" .. filepath .. "_" .. language)

	-- Detect missing packages
	M.detect_missing_packages(filepath, language, function(missing)
		if #missing > 0 then
			notifications.notify_missing_packages(missing, language)
		end
	end)
end

-- Analyze current buffer (async; the callback receives
-- { imports, installed, missing })
function M.analyze_buffer(language, callback)
	local filepath = vim.api.nvim_buf_get_name(0)
	if filepath == "" then
		callback({ imports = {}, missing = {}, installed = {} })
		return
	end

	-- Ensure absolute path
	if not filepath:match("^/") then
		filepath = vim.fn.fnamemodify(filepath, ":p")
	end

	local imports = M.scan_imports(filepath, language)
	M.get_installed_packages(language, filepath, function(installed)
		M.detect_missing_packages(filepath, language, function(missing)
			callback({
				imports = imports,
				installed = installed,
				missing = missing,
			})
		end)
	end)
end

return M
