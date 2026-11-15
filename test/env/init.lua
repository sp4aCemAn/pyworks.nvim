-- Sandbox Neovim config for the pyworks.nvim test environment.
--
-- Used by: container.sh scenarios/e2e/shell, UpdateRemotePlugins bootstrap.
-- NOT used by the unit specs (those run under tests/minimal_init.lua).
--
-- All state (plugins, venvs, kernels, jupytext) lives under the bind-mounted
-- sandbox; the host's real config is never touched.

local repo = os.getenv("PYWORKS_REPO") or "/work/pyworks.nvim"

vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Keep the environment hermetic and quiet.
vim.opt.swapfile = false
vim.opt.backup = false
vim.opt.writebackup = false
vim.opt.shadafile = "NONE"
vim.opt.shortmess:append("I")

-- The sandbox venv is the Python host (pynvim lives there; Molten needs it).
local host_python = os.getenv("PYWORKS_HOST_PYTHON")
if host_python and vim.fn.executable(host_python) == 1 then
	vim.g.python3_host_prog = host_python
end

-- lazy.nvim bootstrap (into $XDG_DATA_HOME/nvim/lazy)
local lazy_dir = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazy_dir) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"--single-branch",
		"https://github.com/folke/lazy.nvim.git",
		lazy_dir,
	})
end
vim.opt.rtp:prepend(lazy_dir)

-- Scenario runs must not race pip/uv: essentials and auto-detect side
-- effects are opt-in via PYWORKS_TEST_ESSENTIALS=1.
local lean = os.getenv("PYWORKS_TEST_ESSENTIALS") ~= "1"

require("lazy").setup({
	{ "nvim-lua/plenary.nvim", lazy = false },
	-- Upstream deps (the jeryldev forks are being cut; pyworks'
	-- dependencies.lua looks plugins up by the "molten-nvim" lazy key).
	{ "benlubas/molten-nvim", name = "molten-nvim", lazy = false, build = ":UpdateRemotePlugins" },
	{ "3rd/image.nvim", lazy = false },
	{
		dir = repo,
		name = "pyworks.nvim",
		lazy = false,
		priority = 1000,
		config = function()
			require("pyworks").setup({
				python = {
					use_uv = os.getenv("PYWORKS_USE_UV") ~= "0",
					auto_install_essentials = not lean,
				},
				notifications = {
					-- Captured verbatim by the scenario runner instead.
					debug_mode = os.getenv("PYWORKS_TEST_DEBUG") == "1",
				},
			})
		end,
	},
}, {
	checker = { enabled = false },
	rocks = { enabled = false },
	git = { timeout = 120 },
})
