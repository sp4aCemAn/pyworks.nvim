# Packages: import extraction → install pipeline → guards

Module: `lua/pyworks/core/packages.lua`. The dangerous one: it turns text
from *possibly untrusted files* into `pip install` commands. Two layers of
guards exist; understand both before touching anything here.

## Pipeline

```
file saved/opened
 └─ detector.rescan_imports (detector.lua:441)
     └─ packages.rescan_for_language (packages.lua:928)
         ├─ cache.invalidate("imports_<path>_<lang>")
         ├─ scan_imports (line 694) ────────────── cached per path+lang
         │    notebook (.ipynb) → reads BUFFER (post-jupytext percent form)
         │    plain file → disk, size-capped at 1 MiB (line 9; enforced line 742)
         │    └─ extract_python_imports (line 614)
         ├─ detect_missing_packages (line 792)
         │    per import: skip stdlib (line 870) / custom (line 820)
         │    → map_import_to_package (line 581)
         │    → not in installed set? → missing
         └─ notifications.notify_missing_packages (line 181 notifications)
              user presses <leader>pi → python.install_missing_packages
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

1. `is_valid_package_name` (line 879) → regex whitelist
   (`^[a-zA-Z0-9_.%-]+...`) — ASCII-only, blocks shell injection AND unicode
   homoglyphs. `validate_package_names` (line 889) splits valid/invalid.
2. `is_typosquat` (line 380) / `filter_typosquats` (line 410):
   `normalize_package_name` (line 315, PEP-503-ish: lower, collapse
   `[-._]+`→`-`) + `edit_distance_at_most` (line 322, bounded Levenshtein).
   Threshold: 2 edits (1 for ≤3-char names). Exact known name in any
   spelling → safe. Version specifiers/extras stripped before matching
   (`numpy[extra]>=2` → base `numpy`).

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
