# Notebook UX foundation refactor — Model A ("Folded Notebook")

Decided 2026-11-16 with the user. Execution unit = slices **F1–F6** below;
this file + `docs/LMS.md` + `AGENTS.md` are the complete brief for a fresh
session. Commits `7c06d73..20317e9` on branch `lspcleanup` were the interim
silence/highlight/formatter work — parts of it are superseded here (F5).

## Doctrine (decided — do not relitigate)

1. **Model A**: the jupytext percent-format script IS the buffer. Notebook
   feel comes from presentation chrome (folds, concealment, virtual text),
   never from secondary editing surfaces.
2. **Single-buffer**: no scratch/split editors, no per-cell buffers
   (buffer-in-buffer rejected after evaluation). All editing happens in the
   notebook buffer itself.
3. **Markdown UX = inline concealment** (F6). Richer markdown *styling*
   (bold/headings as graphics) stays markview.nvim territory — document, do
   not implement.

## Established facts (verified 2026-11-16 — do not re-derive)

### jupytext 1.19.3 percent-canonical markdown

- py:percent **comments markdown cell content by default** (jupytext docs:
  "By default Jupytext will use line comments"). Codec source of truth:
  `jupytext/cell_reader.py::uncomment(lines, "#")` and
  `jupytext/languages.py::comment_lines(lines, "#")`.
- Comment: content line L → `"# " + L`; empty L → `"#"`.
  Uncomment: strip leading `"# "` else leading `"#"` else leave line.
  Examples (from installed jupytext, 1.19.3):
  `["text", "", "# h1", "  indented"]` → `["# text", "#", "# # h1", "#   indented"]`
  `["# text", "#", "#  two spaces", "## h1c", "raw"]` → `["text", "", " two spaces", "# h1c", "raw"]`
- Consequence: canonical notebook buffers are valid Python (md = comments);
  syntax errors only appear transiently from raw lines typed mid-session.

### :syntax cannot style md-in-comments over python (dead end, proven)

- `pythonComment` is `syn match "#.*$"` — top-level, wins the same-position
  tie against any later-defined region on marker/content lines (probes
  2026-11-16: `synstack` showed only `pythonComment` regardless of define
  order once python syntax is loaded).
- `lua/pyworks/notebook/markdown_hl.lua` (shipped `236534f`) therefore
  **never renders** on real notebooks; its specs only passed because spec
  buffers lack `filetype=python`. F5 removes it.

### matchadd() outranks syntax (the F6 lever)

- `:help :syn-priority` vs `:help add-user-highlight`: matchadd matches win.
- Range-gating trick: vim regex `\%>123l` / `\<123l` atoms can bound
  concealment to md content ranges recomputed from the cell model; requires
  `matchdelete` + re-add on change (debounced), `conceal` (no cchar) with
  `concealcursor` + `conceallevel>=2` set per-window on notebook buffers.
- F6 must begin with a throwaway SPIKE (pattern correctness, cursor-motion
  feel across concealed `"# "`, interaction with Molten virt_text, cost of
  re-adding matches) and must record findings here/LMS before building.

### pylsp/pyflakes payload shape (informs F4/F6 filters)

- Whole-file parse failure → single `invalid syntax` diagnostic at the
  FIRST offending line (0-based `range.start.line`).
- nvim >= 0.12 delivers `publishDiagnostics` with `ctx.bufnr = nil`;
  resolve via `vim.uri_to_bufnr(result.uri)` (pattern exists in
  `notebook/lsp.lua` `resolve_bufnr`, commit S9). Keep it.

### Known bug F3 kills

- `keymaps.lua` run-all: `search(pat, "bnW")` with cursor ON a marker line
  returns the PREVIOUS marker ("c" flag missing) → executed ranges shift by
  one cell → adjacent cells double-execute, `[markdown]` skip checks the
  wrong cell. `cell_engine.lua` uses correct `"bcnW"`. After F3 all
  ranges come from the cell model and the failure mode disappears.

## Slices

- [ ] **F1 — `core/cell_model.lua`**: canonical cells
      `{index, marker_line, type, start_line, end_line, marker_text}` +
      `cell_at(bufnr, line)`, `markers(bufnr)`, `markdown_regions(bufnr)`,
      `for_buffer(bufnr)`; preamble (lines before first marker) = implicit
      cell 0; classify `[markdown]` / `[raw]` / custom markers; `vim.validate`
      per AGENTS.md. Specs absorb `get_markdown_regions` tests (keep shim
      delegating). Acceptance: table-driven tests incl. empty file,
      consecutive markers, md-last-to-EOF, custom markers.
- [ ] **F2 — `notebook/percent_md.lua`**: `comment(content_lines)` /
      `uncomment(md_lines)` exactly per Established facts above; round-trip
      property tests (incl. `"## h1"` stability); golden-file tests only if
      a runnable jupytext exists in the environment (skip otherwise —
      container has it).
- [ ] **F3 — migrate consumers to F1**: run-all (fixes bnW bug),
      `is_markdown_cell` (drop keymaps-local copy), `find_cell_boundaries`,
      numbering/folds call-through. Acceptance: new specs assert each cell
      executed exactly once and markdown skipped by TYPE not cursor trick;
      CHANGELOG entry (user-visible double-run fix); container e2e still 7/9
      (2 red = upstream Molten iopub, documented).
- [ ] **F4 — migrate F1/F2 into `notebook/lsp.lua` + `commands/format_cell.lua`**:
      filter regions from model; formatter: uncomment → md_formatter stdin →
      comment → replace content range. Acceptance: format of canonical
      `# text` content round-trips through a stub formatter without h1-soup.
- [ ] **F5 — remove `notebook/markdown_hl.lua` + `notebooks.markdown_highlight`**
      (+ spec, docs, CHANGELOG [Unreleased] fix-note). Commit message cites
      this file's dead-end section.
- [ ] **F6 — `notebook/md_view.lua`**: inline `# ` concealment via
      matchadd-range trick; `notebooks.md_conceal = true` default, new
      option `notebooks.md_fold_default` (collapse md cells on open — the
      surviving half of old S11). SPIKE FIRST (see facts above); document
      findings; then implement or escalate alternatives to the user.

## Obligations per slice (AGENTS.md)

stylua --check lua/ tests/ · ./run_tests.sh green · selene via CI ·
user-visible → CHANGELOG [Unreleased] · flow changes → matching
docs/internals doc with verified file:line anchors · docs/LMS.md state
updated before ending session · public APIs validate · commands/autocmds
have desc · integration_spec expected_commands list kept exact.

## S10–S12 disposition

S10 → F2+F4+F5 · S11 → folded into F6 (`md_fold_default`) ·
S12 (scratch editor) → CANCELLED by single-buffer doctrine.
