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

### F6 SPIKE findings (2026-11-16, executed before building — throwaway
harness: msgpack-RPC driver attaching a real `ext_linegrid` UI to an
embedded nvim 0.12.6 and reading rendered `grid_line`/`grid_cursor` events;
plain headless probes are INCONCLUSIVE for rendering — `virtcol`/`screenpos`
never reflect concealment with no UI attached, they silently return byte
columns)

1. **Line-range atoms**: `\%>=Nl`/`\%<=Nl` DO NOT EXIST (E867 NFA error at
   matchadd — and a bad pattern in a matchadd dict-arg call fails SILENTLY
   at draw time in some paths, so validate via `match()`/`search()` first).
   Only exclusive `\%>Nl`/`\%<Nl`. Inclusive region `[s,e]` →
   `\%>{s-1}l\%<{e+1}l`. Prefix: `^#\s\?` (covers `"# "`-commented and bare
   `"#"` empty md lines).
1b. **`^` anchor branch trap (bit us in review of my own first pattern)**:
   `^` is a line anchor at pattern/`\|`-BRANCH start only when it LEADS the
   branch. `\%>1l\%<4l^#\s\?\|\%>5l\%<8l^#\s\?` — branch 1 matches, branch 2
   finds NOTHING (the `^` behaves as a literal). Same silent failure inside
   `\%(...\)` wrappers (`\%(\%>1l\%<4l^#...` matches nothing). Correct
   multi-region shape: **`^` first in every branch**:
   `^#\s\?\%>1l\%<4l\|^#\s\?\%>5l\%<8l` — confirmed by a real
   ext_linegrid render diffing every md line of BOTH regions plus the bare
   `#` line (driver: attach `ext_linegrid` UI to `nvim --embed` child via
   msgpack-RPC, read `grid_line` deltas; rows are 0-based; `nvim` sends
   Buffer/Window as msgpack EXT → decodes as raw byte strings via plain
   `vim.mpack`).
1c. Plain headless probes CANNOT see concealment: `virtcol`/`screenpos`
   return byte columns with no UI attached — a matchadd that silently
   matches nothing looks identical to working concealment. Any future
   presentation work must use the ext_linegrid driver, unit-assert the
   pattern string + `getmatches()`, or eyeball a real session.
2. **Conceal renders correctly**: with `conceallevel=3` + a matchadd
   `{conceal=""}` (cchar-less = fully hidden), the rendered grid showed
   `# # Title` → `Title` and `# body text` → `body text`; bare `#` → empty
   line. Matched positions are simply not drawn (no width, no chars).
3. **Cursor motion**: byte columns step THROUGH the hidden prefix — `l`
   from col 1 lands on col 2 and 3 (both invisible with
   `concealcursor="nvi"`). Feel = "ghost columns" at line start, the known
   markview-class wart. Editing risk confirmed: `i<BS>` at the prefix
   boundary silently deletes the `# ` space (md text semantics change while
   invisible). Mitigation: `concealcursor="nvi"` — the cursor line is
   never concealed (prefix reappears wherever the cursor is, in normal,
   visual AND insert mode; 'i' listed is mandatory: text under the cursor
   in UNLISTED modes stays hidden). Other md lines stay clean.
4. **Molten virt_text coexists**: an eol `virt_text` extmark ("Out[1]: ✓
   Done") rendered fine on a line whose prefix was concealed — concealment
   shifts nothing, virt_text still appends after the (shifted) eol. No
   conflict with extmark-based Molten output or pyworks_cell_numbers.
5. **Re-add cost is negligible**: 25-50 full rebuilds of 60-80 regions
   (clearmatches + matchadd/matchaddpos, both single `|`-alternation and
   per-region ids) measured 0 ms — debounce is still worthwhile, but cost
   is a non-issue. Multi-region in ONE matchadd via `\%(...\)\|%(...\)`
   alternation verified rendering correctly (one id to manage/replace).
6. **`matchaddpos`** accepts >8 position tuples in 0.12 (no legacy cap) —
   but positions are dead coordinates (stale after edits); pattern ranges
   stay live across scroll, only go stale on line-count edits. Chosen:
   one pattern-match, rebuild on debounce.
7. **Folds coexist** with conceal (foldmethod=expr + matchadd in same
   window: fine). `md_fold_default` (collapse md cells on open) builds on
   this: foldexpr already marks folds at markers; need per-fold close,
   which requires knowing md fold extents → cell model (F1) gives them.
8. Window-scoped: matches are per-window (`clearmatches()` hits the
   current window only) → attach per notebook window on WinNew/BufWinEnter
   with conceallevel/concealcursor set alongside.

### F6 build decisions (from spike)

- One buffer-global pattern (`\|`-joined branches, each `^#\s\?\%>{s-1}l\
  \%<{e+1}l` — `^` leads every branch, spike #1b) over the markdown regions
  from `cell_model.markdown_regions` + ONE matchadd id per window; rebuild
  debounced 150ms on changes, immediate on BufWinEnter/WinEnter;
  `matchdelete` + re-add via stable id.
- Window options on notebook buffers only: `conceallevel=2`,
  `concealcursor="nvi"` (spike #3: in normal/visual/insert the char under
  the cursor is un-concealed so you can reach/edit the prefix; other lines
  stay clean; 'i' is mandatory for insert-mode safety).
- `notebooks.md_conceal` (default true) gates the whole module;
  `notebooks.md_fold_default` (default false) closes md folds on open.
- Escape hatch: `:PyworksMdConceal` toggle? No — config option suffices
  (single-buffer doctrine, minimal surface). Users toggle via setup().

### pylsp/pyflakes payload shape (informs F4/F6 filters)

- Whole-file parse failure → single `invalid syntax` diagnostic at the
  FIRST offending line (0-based `range.start.line`).
- nvim >= 0.12 delivers `publishDiagnostics` with `ctx.bufnr = nil`;
  resolve via `vim.uri_to_bufnr(result.uri)` (pattern exists in
  `notebook/lsp.lua` `resolve_bufnr`, commit S9). Keep it.

### Known bug F3 kills — FIXED (F3)

- `keymaps.lua` run-all: `search(pat, "bnW")` with cursor ON a marker line
  returned the PREVIOUS marker ("c" flag missing) → executed ranges shift by
  one cell → adjacent cells double-execute, `[markdown]` skip checks the
  wrong cell. `cell_engine.lua` uses correct `"bcnW"`. After F3 all
  ranges come from the cell model and the failure mode disappears.
  F3 landed: run-all snapshots `cell_model.markers`, evaluates exact
  `[start_line,end_line]`; regression test in keymaps_spec asserts
  cursor-position independence + each code cell once + md skipped by type.

## Slices

- [x] **F1 — `core/cell_model.lua`**: canonical cells
      `{index, marker_line, type, start_line, end_line, marker_text}` +
      `cell_at(bufnr, line)`, `markers(bufnr)`, `markdown_regions(bufnr)`,
      `for_buffer(bufnr)`; preamble (lines before first marker) = implicit
      cell 0; classify `[markdown]` / `[raw]` / custom markers; `vim.validate`
      per AGENTS.md. Specs absorb `get_markdown_regions` tests (keep shim
      delegating). Acceptance: table-driven tests incl. empty file,
      consecutive markers, md-last-to-EOF, custom markers.
- [x] **F2 — `notebook/percent_md.lua`**: `comment(content_lines)` /
      `uncomment(md_lines)` exactly per Established facts above; round-trip
      property tests (incl. `"## h1"` stability); golden-file tests only if
      a runnable jupytext exists in the environment (skip otherwise —
      container has it).
- [x] **F3 — migrate consumers to F1**: run-all (fixes bnW bug),
      `is_markdown_cell` (drop keymaps-local copy), `find_cell_boundaries`,
      numbering/folds call-through. Acceptance: new specs assert each cell
      executed exactly once and markdown skipped by TYPE not cursor trick;
      CHANGELOG entry (user-visible double-run fix); container e2e still 7/9
      (2 red = upstream Molten iopub, documented).
- [x] **F4 — migrate F1/F2 into `notebook/lsp.lua` + `commands/format_cell.lua`**:
      filter regions from model; formatter: uncomment → md_formatter stdin →
      comment → replace content range. Acceptance: format of canonical
      `# text` content round-trips through a stub formatter without h1-soup.
- [x] **F5 — remove `notebook/markdown_hl.lua` + `notebooks.markdown_highlight`**
      (+ spec, docs, CHANGELOG [Unreleased] fix-note). Commit message cites
      this file's dead-end section.
- [x] **F6 — `notebook/md_view.lua`**: inline `# ` concealment via
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
