-- E2E Molten smoke test for pyworks.nvim (container test env).
--
-- Precondition (done by container.sh e2e before nvim starts):
--   /sandbox/e2e/proj contains requirements.txt + a REAL venv (.venv with
--   ipykernel importable) + nb.ipynb with a cell printing "pyworks-e2e 42".
--
-- Exercises the full fragile chain end to end:
--   BufReadCmd jupytext conversion -> FileType handler ->
--   detector.handle_python_notebook -> kernel discovery/creation ->
--   MoltenInit -> run_cell -> virtual-text completion polling ->
--   BufWriteCmd round-trip back to valid JSON.

local proj = vim.env.PYWORKS_E2E_PROJ or "/sandbox/e2e/proj"
local nb = proj .. "/nb.ipynb"
local needle = "pyworks-e2e 42"

local fails = 0
local captured = {}
vim.notify = function(msg, _)
	table.insert(captured, tostring(msg))
end

local function step(ok, label, extra)
	if not ok then
		fails = fails + 1
		print("FAIL: " .. label)
		if extra then
			print("  hint: " .. tostring(extra))
		end
	else
		print("ok: " .. label)
	end
end

print("=== pyworks e2e smoke (" .. nb .. ") ===")

if vim.fn.filereadable(nb) ~= 1 then
	print("FAIL: fixture missing (container.sh bug?)")
	pcall(vim.cmd, "cquit 1")
end

vim.cmd("edit " .. vim.fn.fnameescape(nb))

-- 1) jupytext conversion produced percent-format python, not raw JSON
local conv = vim.wait(10000, function()
	return vim.bo.filetype == "python"
end, 100)
step(conv, "notebook converted to percent format (ft=python)")
step(not (vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] or ""):match("^%s*{"), "buffer is not raw JSON")

-- 2) kernel auto-init: the flag lands when MoltenInit RETURNS; the kernel
-- itself boots async and Molten fires User MoltenKernelReady. pyworks'
-- ready-hook evaluates a pandas snippet 500ms later, whose overlapping-cell
-- delete wipes any in-flight cell output (race doc: ENVIRONMENT_PLAN).
-- So: flag -> ready event -> settle, before running our cell.
local bufnr = vim.api.nvim_get_current_buf()
vim.api.nvim_create_autocmd("User", {
	pattern = "MoltenKernelReady",
	callback = function()
		vim.g.e2e_kernel_ready = true
	end,
	desc = "e2e: observe kernel readiness",
})
local inited = vim.wait(30000, function()
	return vim.b[bufnr].molten_initialized == true
end, 200)
local ready = vim.wait(30000, function()
	return vim.g.e2e_kernel_ready == true
end, 200)
if not inited then
	step(
		false,
		"Molten kernel auto-initialized",
		"attempted="
			.. tostring(vim.b[bufnr].molten_init_attempted)
			.. " | last notifications: "
			.. table.concat(captured, " || "):sub(1, 500)
	)
end
step(inited, "Molten kernel auto-initialized (detector created/selected kernel)")

if inited then
	-- Wait for pyworks' MoltenKernelReady pandas eval to FINISH (cold
	-- `import pandas` takes seconds). Concurrent evaluations confuse
	-- Molten's span attribution; a human is implicitly serialized here.
	local function any_done_extmark()
		local mid = vim.api.nvim_get_namespaces()["molten-extmarks"]
		if not mid then
			return false
		end
		for _, m in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, mid, 0, -1, { details = true })) do
			for _, line in ipairs(m[4] and m[4].virt_lines or {}) do
				local parts = {}
				for _, seg in ipairs(line) do
					table.insert(parts, seg[1])
				end
				if table.concat(parts):find("Done", 1, true) then
					return true
				end
			end
		end
		return false
	end
	step(vim.wait(90000, any_done_extmark, 250), "ready-hook pandas eval finished before user eval")

	-- 3) run the cell through the real pyworks path
	local cell_engine = require("pyworks.core.cell_engine")
	local keymaps = require("pyworks.keymaps")

	local before = keymaps._get_highest_completed_output(bufnr)
	local ran = cell_engine.run_cell()
	step(ran, "run_cell() dispatched")

	-- 4) completion detection via Molten virtual-text polling
	local done = vim.wait(90000, function()
		return keymaps._get_highest_completed_output(bufnr) > before
	end, 200)
	step(done, "Out[N] completion detected by extmark polling")

	-- 5) actual output text made it into Molten's virtual lines
	local function output_contains(text)
		local ns = vim.api.nvim_get_namespaces()["molten-extmarks"]
		if not ns then
			return false
		end
		for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(bufnr, ns, 0, -1, { details = true })) do
			local d = mark[4]
			for _, group in ipairs({ d and d.virt_text or {}, d and d.virt_lines or {} }) do
				for _, line in ipairs(group) do
					local parts = {}
					for _, seg in ipairs(line) do
						table.insert(parts, seg[1] or seg[2] or "")
					end
					if table.concat(parts):find(text, 1, true) then
						return true
					end
				end
			end
		end
		return false
	end
	local out_seen = vim.wait(10000, function()
		return output_contains(needle)
	end, 200)
	if not out_seen then
		-- dump everything Molten left behind for diagnosis
		local ns = vim.api.nvim_get_namespaces()
		local keys = {}
		for k in pairs(ns) do
			table.insert(keys, k)
		end
		print("  [diag] namespaces: " .. table.concat(keys, ","))
		local mid = ns["molten-extmarks"]
		if mid then
			local dump = vim.json.encode(vim.api.nvim_buf_get_extmarks(bufnr, mid, 0, -1, { details = true }))
			print("  [diag] FULL extmark dump: " .. dump:sub(1, 4000))
		else
			print("  [diag] no molten-extmarks namespace")
		end
		-- maybe output landed in Molten's float window buffer instead
		for _, w in ipairs(vim.api.nvim_list_wins()) do
			local wb = vim.api.nvim_win_get_buf(w)
			local name = vim.api.nvim_buf_get_name(wb)
			if name:match("[Mm]olten") or (vim.b[wb] and vim.b[wb].molten_output) then
				print(
					"  [diag] molten win buf="
						.. name
						.. " lines: "
						.. table.concat(vim.api.nvim_buf_get_lines(wb, 0, 20, false), " | ")
				)
			end
		end
		print("  [diag] notifications: " .. table.concat(captured, " || "):sub(1, 600))
	end
	step(out_seen, "cell output '" .. needle .. "' rendered in virt text")

	-- 6) save round-trips back to valid notebook JSON with our code inside
	vim.cmd("write")
	local ok_json, nb_json = pcall(function()
		return vim.json.decode(table.concat(vim.fn.readfile(nb), "\n"))
	end)
	step(ok_json and nb_json and nb_json.nbformat == 4, "saved file is nbformat-4 JSON")
	local src_ok = false
	if ok_json and nb_json and nb_json.cells then
		for _, cell in ipairs(nb_json.cells) do
			local src = type(cell.source) == "table" and table.concat(cell.source, "") or tostring(cell.source)
			if src:find("pyworks-e2e", 1, true) then
				src_ok = true
			end
		end
	end
	step(src_ok, "round-tripped notebook preserves cell source")
end

vim.fn.writefile({ tostring(fails) }, "/sandbox/results/e2e.status")
if fails > 0 then
	print(string.format("=== e2e: %d FAILURES ===", fails))
	pcall(vim.cmd, "cquit 1")
else
	print("=== e2e: all steps passed ===")
end
