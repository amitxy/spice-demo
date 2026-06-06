---
name: run-server-ui
argument-hint: "[restart | rebuild]"
description: Rebuild and/or restart the server-ui. Use when asked to refresh, rebuild, test, or preview the UI, or after editing server/ui/src/, server/constitutions.json, server/inference-config.json, or data/constitutions/.
allowed-tools:
  - Bash(bash server/build.sh *)
  - Bash(bash .claude/skills/run-server-ui/restart-server.sh *)
---

The server-ui is a SvelteKit static app in `server/ui/`. It builds to `server/ui/dist/`, which is copied into the llama.cpp submodule and embedded into the `llama-server` binary at compile time.

All commands run from the **repo root** (`/workspace/spice-demo`).

## Arguments

| Argument | When to use |
|----------|-------------|
| `restart` | Server config changed (e.g. `inference-config.json`, `chat_template.jinja`) — no UI source changes. Just kills and restarts llama-server. Fast (~2 min). |
| `rebuild` | UI source changed (`server/ui/src/`, constitutions, `inference-config.json`). Rebuilds the SvelteKit bundle, copies dist, then restarts. Slow (~5 min). |

Default (no argument) = `rebuild`.

## restart — server only

Use after changes to `server/chat_template.jinja` or `server/inference-config.json` that don't require a UI rebuild.

```bash
bash .claude/skills/run-server-ui/restart-server.sh
```

If no llama-server is running it exits silently. Logs: `/tmp/llama-server.log`.

## rebuild — UI rebuild + restart

Use after changes to any `server/ui/src/` files, `server/constitutions.json`, `data/constitutions/*.md`, or `server/inference-config.json`.

```bash
bash server/build.sh --ui-only
bash .claude/skills/run-server-ui/restart-server.sh
```

Expected build output ends with:
```
✓ Wrote site to "./dist"
✔ done
```

## Prerequisites

Node ≥ 18, npm ≥ 10. Run once if `node_modules` is missing:

```bash
cd server/ui && npm install && cd ../..
```

## Gotchas

- **`--ui-only` does NOT update the running binary.** llama-server embeds the UI JS at cmake compile time. `--ui-only` updates the dist on disk and the restart picks it up — but only because restart re-reads the disk dist at startup. A full `bash server/build.sh` (binary recompile) is only needed when the llama.cpp C++ code itself changes.
- `chat_template.jinja` changes take effect on restart alone (no rebuild needed) — the template is read from the filesystem at server startup via `--chat-template-file`.
- `server/inference-config.json` changes take effect on restart alone at the server level (the `--chat-template-kwargs` python one-liner re-reads the file). A rebuild is also needed if you want the UI's per-request override to pick up the new value.
