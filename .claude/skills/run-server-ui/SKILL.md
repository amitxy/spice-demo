---
name: run-server-ui
argument-hint: "[restart | rebuild]"
description: Rebuild and/or restart the server-ui. Use when asked to refresh, rebuild, test, or preview the UI, or after editing server/ui/src/, server/constitutions.json, server/inference-config.json, or data/constitutions/.
context: fork
model: sonnet
allowed-tools:
  - Bash(bash server/build.sh *)
  - Bash(bash */.claude/skills/run-server-ui/restart-server.sh *)
---

The server-ui is a SvelteKit static app in `server/ui/`. It builds to `server/ui/dist/`, which is copied into the llama.cpp submodule and embedded into the `llama-server` binary at compile time.

All commands run from the **repo root** (`/workspace/spice-demo`).

## Arguments

| Argument | When to use |
|----------|-------------|
| `restart` | Server config changed (e.g. `inference-config.json`, `chat_template.jinja`) — no UI source changes. Just kills and restarts llama-server. Fast (~2 min). |
| `rebuild` | UI source changed (`server/ui/src/`, constitutions, `inference-config.json`). Rebuilds the SvelteKit bundle, copies dist, **recompiles the binary** so the new UI is embedded, then restarts. Slow (~5 min). |

Default (no argument) = `rebuild`.

## restart — server only

Use after changes to `server/chat_template.jinja` or `server/inference-config.json` that don't require a UI rebuild.

```bash
bash .claude/skills/run-server-ui/restart-server.sh
```

If no llama-server is running it exits silently. Logs: `/tmp/llama-server.log`.

## rebuild — UI rebuild + binary recompile + restart

Use after changes to any `server/ui/src/` files, `server/constitutions.json`, `data/constitutions/*.md`, or `server/inference-config.json`.

llama-server **embeds the UI into the binary at cmake compile time**, so changing the
on-disk dist is not enough — the binary must be recompiled to re-embed it. `bash server/build.sh`
(no flag) does the full chain: build UI → copy dist into the submodule → recompile the binary.

```bash
bash server/build.sh
bash .claude/skills/run-server-ui/restart-server.sh
```

Expected build output ends with the UI write, then the binary link:
```
  Wrote site to "./dist"
  ✔ done
...
==> Binary: .../server/llama.cpp/build/bin/llama-server
```

Verify the running server actually serves the new bundle (catches the "I rebuilt but
nothing changed" trap):
```bash
diff <(curl -s http://localhost:8000/bundle.js | md5sum | cut -d' ' -f1) \
     <(md5sum server/ui/dist/bundle.js | cut -d' ' -f1) \
  && echo "served bundle matches disk" || echo "MISMATCH — binary still has stale UI embedded"
```

## Prerequisites

Node ≥ 18, npm ≥ 10. Run once if `node_modules` is missing:

```bash
cd server/ui && npm install && cd ../..
```

## Gotchas

- **`--ui-only` + restart does NOT update what the server serves.** llama-server embeds the UI assets into the binary at cmake compile time (via `tools/ui/dist/` → `libllama-ui.a`). Restarting the same binary just re-serves the *embedded* (old) bundle — it does **not** re-read the on-disk dist. Any UI source change requires a binary recompile: `bash server/build.sh` (full) or `bash server/build.sh --bin-only` (if the dist was already copied by a prior `--ui-only`). The `rebuild` path above handles this. Symptom of getting this wrong: the on-disk `dist/bundle.js` has your change but `curl http://localhost:8000/bundle.js` does not — the md5sums differ.
- `chat_template.jinja` changes take effect on restart alone (no rebuild needed) — the template is read from the filesystem at server startup via `--chat-template-file`.
- `server/inference-config.json` changes take effect on restart alone at the server level (the `--chat-template-kwargs` python one-liner re-reads the file). A rebuild is also needed if you want the UI's per-request override to pick up the new value.
