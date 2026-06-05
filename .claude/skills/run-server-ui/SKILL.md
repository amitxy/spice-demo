---
name: run-server-ui
description: Rebuild and preview the server-ui SvelteKit app after source changes. Use when asked to refresh, rebuild, test, or preview the UI, or after editing server/ui/src/, server/constitutions.json, server/inference-config.json, or data/constitutions/.
allowed-tools:
  - Bash(bash server/build.sh *)
  - Bash(bash .claude/skills/run-server-ui/restart-server.sh *)
---

The server-ui is a SvelteKit static app in `server/ui/`. It is built and its `dist/` is copied into the llama.cpp submodule, which then embeds it in the `llama-server` binary. The full server requires CUDA + model files, but the UI can be rebuilt and previewed locally in isolation.

All commands below run from the **repo root** (`/workspace/spice-demo`).

## Prerequisites

Node ≥ 18, npm ≥ 10. Verified working: Node v24.14.1, npm 11.11.0.
`node_modules` must be present — run once if missing:

```bash
cd server/ui && npm install && cd ../..
```

## Rebuild UI (primary agent path)

Regenerates embedded data files, runs the vite build, and copies `dist/` into the submodule. This is the single command to run after any UI source change:

```bash
bash server/build.sh --ui-only
```

Expected output ends with:
```
✓ Wrote site to "./dist"
✔ done
```

To just type-check without building:

```bash
cd server/ui && npm run check
```

Expected: `svelte-check found 0 errors and 0 warnings`

## Preview built UI locally

After rebuilding, serve the static dist on port 4173 to visually inspect the result without needing llama-server running. API calls will fail (no backend), but layout, styles, and component rendering are fully checkable:

```bash
cd server/ui && npm run preview -- --port 4173 --host 0.0.0.0
```

UI is served at `http://localhost:4173/`. Kill with Ctrl-C when done.

## After rebuild — restart a running llama-server

llama-server embeds the UI dist at startup, so a running instance must be restarted to pick up the new build. The restart script detects the live router process, kills it cleanly, restarts it with the exact same args, and waits until `/health` returns 200:

```bash
bash .claude/skills/run-server-ui/restart-server.sh
```

If no llama-server is running it exits silently. Logs from the restarted process go to `/tmp/llama-server.log`.

## What triggers a rebuild

Rebuild whenever any of these change:
- `server/ui/src/` — SvelteKit source (components, stores, services, types)
- `server/constitutions.json` or `data/constitutions/*.md` — constitution content (embedded at build time by `generate-constitutions.mjs`)
- `server/inference-config.json` — inference config including `thinking_prefix` (embedded by `generate-inference-config.mjs`)

## Gotchas

- **`--ui-only` does NOT update the running binary.** The llama-server binary embeds the UI JavaScript at cmake compile time (into `libllama-server-impl.so`). `bash server/build.sh --ui-only` updates the dist on disk but the running server keeps serving the old embedded bundle. A full `bash server/build.sh` (which recompiles the binary) is required to make JS changes take effect in production. For config-only changes (e.g. `inference-config.json`), updating the server-level `--chat-template-kwargs` at restart is sufficient.
- `server/ui/scripts/dev.sh` references `tools/ui/` paths from upstream llama.cpp — do **not** use `npm run dev` for this project; it won't work.
- The prebuild scripts (`generate-constitutions.mjs`, `generate-inference-config.mjs`) run automatically as part of `npm run build` / `bash server/build.sh --ui-only` — no need to run them separately.
- The vite build takes ~40–60 seconds and produces a large bundle (~8 MB JS); the chunk-size warning is expected and harmless.
- `npm run preview` serves the static dist without a backend — constitution selector and model loading will show errors in the browser console, which is normal.
