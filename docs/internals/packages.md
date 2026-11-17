# Packages: import extraction → install pipeline → guards

Module: `lua/pyworks/core/packages.lua`. The dangerous one: it turns text
from *possibly untrusted files* into `pip install` commands. Two layers of
guards exist; understand both before touching anything here.

## Pipeline

```
file saved/opened
 └─ detector.rescan_imports
     └─ packages.rescan_for_language (async internally)
         ├─ cache.invalidate("imports_<path>_<lang>")
         ├─ scan_imports ────────────── cached per path+lang
         │    notebook (.ipynb) → reads BUFFER (post-jupytext percent form)
         │    plain file → disk, size-capped at 1 MiB (enforced in scan)
         │    └─ extract_python_imports (comment text stripped first, v0.4.0)
         ├─ detect_missing_packages (ASYNC: installed list via callback;
         │    cached per PROJECT root under "installed_packages_<lang>_<root>")
         │    per import: skip stdlib / custom
         │    → map_import_to_package
         │    → not in installed set? → missing
         └─ notifications.notify_missing_packages
              user presses <leader>pi → python.install_missing_packages
              (state key scoped by packages.sync_scope: "project" default)
```

## Extraction details (extract_python_imports, packages.lua:614)

- Two normalization `gsub` passes flatten parenthesized multi-line imports
  (lines ~630-645), then line-wise matching of
  `^import a, b as c` / `^from x.y import z`.
- `add_import` (line 618): keeps the **dotted prefix** if it is a known
  multi-segment mapping (`dotted_import_prefixes`, line 362 — built from
  keys containing `.` in `package_mappings`), else truncates to the root
  identifier. This kills the `google` dependency-confusion case
  (`from google.cloud import ...` → `google.cloud` → `google-cloud-storage`).
- Relative imports (`from . import x`) and comments are skipped; alias
  names are never collected (tested).

## Mappings & known names

- `package_mappings.python` (line 33): import→PyPI table (~100 curated
  entries incl. 2025 AI stack). `reverse_package_mappings` (line 154) maps
  lowercase PyPI→import for installed-checks.
- `popular_packages` (line 178) + mapping values → `known_packages`
  (line 349, normalized). **This set is security-critical**: it defines
  what counts as a typosquat victim. Growing it is normal; shrinking it
  needs review. Curate false-positives into it (e.g. `httpie` sits 2 edits
  from `httpx`).

## Guards (in order, all before any subprocess)

1. `is_valid_package_name` → four anchored patterns (v0.4.0, replaces the
   old permissive regex): name body `[A-Za-z0-9_][A-Za-z0-9_.%-]*` plus an
   optional BALANCED extras group, optional version specifier
   (`<ops><digits/dots>`). Leading `-` is rejected outright — that is pip
   **option injection**, not a name (array-form argv prevents shell
   injection; pip would still parse `--index-url` as its own option).
   NOTE (LuaJIT): the patterns avoid `(...)?` — LuaJIT's pattern engine
   does not support `?` applied to a capture group. `validate_package_names`
   splits valid/invalid and is called FIRST in `python.install_packages`
   (before any venv work) and in the uninstall path.
2. `is_typosquat` / `filter_typosquats`:
   `normalize_package_name` (PEP-503-ish: lower, collapse `[-._]+`→`-`),
   then three rules in order: (1) exact known name in any
   spelling → safe; (2) **prefix-squat** — candidate (≥5 chars) that is a
   proper prefix of a known package is flagged with the closest/shortest
   such name; (3) bounded Levenshtein via `edit_distance_at_most`:
   ≤2 edits (≤3-char names: 1). Version specifiers/extras stripped before
   matching. **Equal-distance ties resolve lexicographically** (v0.4.0) so
   the reported canonical name is deterministic across processes.

## Enforcement points (python.lua:433 install_packages)

- Auto paths (`packages.install_packages` line 903;
  `python.install_missing_packages` line 682 — the `<leader>pi`/PyworksSync
  flow): suspicious names **hard-blocked**, notification names the closest
  known package; remaining safe list proceeds.
- `:PyworksAdd` → `python.install_python_packages` (line 713) passes
  `opts.user_intent = true`: warns but proceeds (explicit user intent is the
  escape hatch; the *auto* block is the supply-chain defense since content
  is untrusted input).
- `install_essentials` uses the static config list — by design NOT filtered
  (additions there are code-reviewed).

## Invariants

- Never install a name that did not pass `validate_package_names` *and* the
  typosquat policy for its path (auto=block, manual=warn).
- `scan_imports` cache key is `imports_<absopath>_<lang>`; rescan MUST
  invalidate before computing (packages.lua:928) or stale names get
  suggested.
- python.lua ↔ packages.lua is a deliberate require cycle broken by the
  lazy `get_packages()` accessor (python.lua:13) — preserve it.

## Covered by

- `tests/packages_spec.lua` (extraction, mappings, typosquat matrix,
  dotted-prefix case), `tests/python_security_spec.lua`,
  `tests/integration_spec.lua` package-scanning block.
