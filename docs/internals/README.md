# pyworks.nvim — Internals (agent onboarding map)

Point an agent here to answer "how does this plugin work" without reading
20 Lua files. Each doc covers one flow with `file:line` anchors, the
**invariants** that must not break, and the tests that guard them.

## The system in 60 seconds

```
                    ┌─────────────────────────────────────────────┐
 open .py / .ipynb  │  plugin/pyworks.lua  (autocmd loader)       │
 ──────────────────►│  BufReadPost/FileType/BufWritePost/         │
                    │  SessionLoadPost/BufWinEnter                │
                    └───────────────┬─────────────────────────────┘
                                    │ defer 100ms
                    ┌───────────────▼─────────────────────────────┐
                    │  core/detector.lua  on_file_open            │
                    │  routes: .py → handle_python                │
                    │        .ipynb → handle_notebook → jupytext  │
                    └───────┬───────────────────────┬─────────────┘
                            │                       │
             ┌──────────────▼─────────┐   ┌─────────▼──────────────┐
             │ languages/python.lua   │   │ notebook/jupytext.lua  │
             │ venv create/essentials │   │ .ipynb ⇄ percent format│
             │ (uv or pip detection)  │   │ BufReadCmd/BufWriteCmd │
             └──────────┬─────────────┘   └─────────┬──────────────┘
                        │                           │ any :edit MUST pass
             ┌──────────▼─────────────┐   ┌─────────▼──────────────┐
             │ core/packages.lua      │   │ core/recursion_guard   │
             │ imports→missing→install│   │ (E132 cascade breaker) │
             │ (+typosquat guard)     │   └────────────────────────┘
             └──────────┬─────────────┘
                        │ kernel needed
             ┌──────────▼──────────────────────────────┐
             │ detector kernel logic → Molten          │
             │ keymaps.lua + core/cell_engine.lua      │
             │ run cell via MoltenEvaluateRange;       │
             │ completion scraped from virtual text    │
             └─────────────────────────────────────────┘

 infrastructure (used by all of the above):
   core/cache.lua (TTL) · core/state.lua (persisted JSON) ·
   core/notifications.lua (dedup/suppression) · core/error_handler.lua ·
   utils.lua (paths + system wrappers) · ui.lua (cell numbers/folds/floats)
```

## Reading order

1. [startup.md](startup.md) — load order and the deferred-init trap
2. [detection.md](detection.md) — how files get routed (the entry point for most bugs)
3. [environment.md](environment.md) — venv/package-manager machinery
4. [packages.md](packages.md) — import→install pipeline + security guards
5. [notebooks.md](notebooks.md) — .ipynb round-trip + the recursion problem
6. [execution.md](execution.md) — kernels, Molten, cell run-all polling
7. [infrastructure.md](infrastructure.md) — cache/state/notifications semantics

## Module → responsibility (file counts from `lua/pyworks/`)

| File | Responsibility | Deep-dive |
|---|---|---|
| `plugin/pyworks.lua` | autocmd loader, notebook reload policy | detection, notebooks |
| `init.lua` | setup(), config, user commands | startup |
| `core/detector.lua` | routing entry point, kernel discovery | detection, execution |
| `languages/python.lua` | venv + package manager ops | environment |
| `core/packages.lua` | imports, mappings, guards | packages |
| `notebook/jupytext.lua` | .ipynb ⇄ percent conversion | notebooks |
| `core/recursion_guard.lua` | notebook :edit cascade breaker | notebooks |
| `keymaps.lua` | user maps + Molten completion polling | execution |
| `core/cell_engine.lua` | cell CRUD + run_cell | execution |
| `ui.lua` | cell numbers, folding, float windows | execution |
| `core/cache.lua` | TTL cache | infrastructure |
| `core/state.lua` | memory + persisted state | infrastructure |
| `core/notifications.lua` | deduped, context-aware notify | infrastructure |
| `core/error_handler.lua` | protected_call, validators | infrastructure |
| `utils.lua` | project paths, system wrappers | detection, environment |
| `dependencies.lua` | lazy.nvim dep checks, image backend | startup |
| `commands/create.lua` | PyworksNewPython{,Notebook} | notebooks |
| `health.lua` / `diagnostics.lua` | :checkhealth / :PyworksDiagnostics | infrastructure |

## House rules these docs follow

- Anchors are `path.lua:line function_name` — verified against the tree at
  authoring time; trust the **function name** over the line if drift occurs.
- Cross-cutting style/security rules live in `../../AGENTS.md`; behavior
  changes must update the matching doc here (see docs/LMS.md etiquette).
