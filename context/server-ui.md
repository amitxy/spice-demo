# Inference Server & UI Architecture

## Directory layout

```
server/
  llama.cpp/          — git submodule, clean upstream (gguf-v0.19.0-447). DO NOT modify.
  ui/                 — SvelteKit app (our custom code, builds to ui/dist/)
  chat_template.jinja — Qwen3.5 Jinja template with constitution prefix injection
  constitutions.json  — name → path map for all constitutions (paths relative to server/)
  build.sh            — one-command build: UI → copy dist → compile binary
  models/             — gitignored; GGUF files placed here manually
```

## Build system

```bash
bash server/build.sh              # full build: UI + binary
bash server/build.sh --ui-only    # rebuild UI only (after editing server/ui/ or constitutions)
bash server/build.sh --bin-only   # recompile binary (dist already in place)
```

**How the custom UI gets into llama.cpp without patching it:**
llama.cpp's `scripts/ui-assets.cmake` has a Priority 1 check: if `tools/ui/dist/` already exists, it uses those files directly and skips its own npm build. `tools/ui/dist/` is gitignored inside the submodule. `build.sh` copies `server/ui/dist/` there after building, then runs cmake with `-DLLAMA_BUILD_UI=OFF`. The submodule stays clean and unmodified.

**Rebuild UI whenever:** `server/ui/src/`, `server/constitutions.json`, or `data/constitutions/*.md` change.

## Run command

```bash
server/llama.cpp/build/bin/llama-server \
  --models-dir server/models --models-max 1 \
  --jinja --chat-template-file server/chat_template.jinja \
  --chat-template-kwargs "$(python3 -c "import json; print(json.dumps(json.load(open('server/inference-config.json'))))")" \
  --host 0.0.0.0 --port 8000 \
  --n-gpu-layers 999 --ctx-size 32768 --parallel 2 --cont-batching \
  --reasoning-format deepseek --reasoning on
```

- `--models-dir` + `--models-max 1`: router mode — hot-swaps GGUFs on demand, one loaded at a time
- `--jinja --chat-template-file`: loads our custom Jinja template from a file (not a literal string)
- `--reasoning-format deepseek`: exposes `<think>` tokens as `reasoning_content` in API responses

UI: `http://localhost:8000` · Health: `GET /health` · Models: `GET /v1/models`

## Chat template & constitution prefix injection (`server/chat_template.jinja`)

At generation time the template injects into `<think>` conditionally:

```jinja
{%- if add_generation_prompt %}
    {{- '<|im_start|>assistant\n' }}
    {%- if enable_thinking is defined and enable_thinking is false %}
        {{- '<think>\n\n</think>\n\n' }}
    {%- else %}
        {{- '<think>\n' }}
        {%- if has_constitution is defined and has_constitution and thinking_prefix is defined and thinking_prefix %}
            {{- thinking_prefix + '\n' }}
        {%- endif %}
    {%- endif %}
{%- endif %}
```

- `thinking_prefix` — sourced from `server/inference-config.json` two ways: (1) **server-level default** via `--chat-template-kwargs` at startup (always active); (2) **per-request override** sent by the UI (only active after a full `bash server/build.sh` binary recompile, since the binary embeds the UI at cmake time). To change the prefix, edit `server/inference-config.json` and restart the server (server-level takes effect immediately; UI per-request takes effect after next full build). **Critical**: the prefix text must end with a forward-looking phrase like "before responding." — a declarative ending causes the model to close `<think>` immediately without generating additional reasoning.
- `has_constitution` — sent **per-request** by the UI (`chat_template_kwargs.has_constitution`); never set server-wide (doing so pollutes the KV cache on warmup requests)

## Constitutions

`server/constitutions.json` maps display names → markdown paths (relative to `server/`):
```json
[{ "name": "Anti China Censorship", "path": "../data/constitutions/A_anti_china_censorship.md" }, ...]
```

`server/ui/scripts/generate-constitutions.mjs` runs at build time, reads this JSON + the markdown files, and writes all content into `src/lib/data/constitutions-data.ts` (statically embedded in the UI bundle).

At runtime, selecting a constitution injects `<CONSTITUTION>\n{content}\n</CONSTITUTION>` as the system message.

## UI architecture (`server/ui/`)

SvelteKit + Svelte 5 runes, static adapter, IndexedDB persistence via Dexie, TypeScript.

### Store layer (`src/lib/stores/`)

| File | Purpose |
|------|---------|
| `chat.svelte.ts` | `ChatStore` class — full message lifecycle (send → stream → persist). Owns `activePersonalityName` and `messagePersonalities: SvelteMap`. |
| `conversations.svelte.ts` | Conversation list, active conversation, message tree navigation |
| `server.svelte.ts` | Detects MODEL vs ROUTER mode from `/props` endpoint; `isRouterMode()`, `contextSize()` |
| `models.svelte.ts` | Model list + selected model (relevant only in ROUTER mode) |
| `settings.svelte.ts` | All UI config, persisted to localStorage |

### Service layer (`src/lib/services/`)

| File | Purpose |
|------|---------|
| `chat.service.ts` | Stateless — builds request body, streams `/v1/chat/completions`. Merges `has_constitution` into `chat_template_kwargs` per-request. |
| `database.service.ts` | Dexie wrapper. `DatabaseMessage` is the canonical stored shape (includes `personalityName`, `model`, `timings`). |

### Key patterns

**`has_constitution` O(1) flag**: `ChatStore` sets `apiOptions.hasConstitution = this.activePersonalityName != null` before calling `chat.service.ts`. The service merges it into the request:
```typescript
requestBody.chat_template_kwargs = {
    ...(requestBody.chat_template_kwargs ?? {}),
    enable_thinking: enableThinking,
    has_constitution: hasConstitution ?? false,
    ...(hasConstitution && thinkingPrefix ? { thinking_prefix: thinkingPrefix } : {})
};
```
This avoids scanning the message list in the Jinja template on every generation.

**Personality stamping**: `personalityName` is written to `DatabaseMessage` and IndexedDB *before* streaming starts, so constitution context survives page reloads. Components resolve it as `message.personalityName ?? chatStore.messagePersonalities.get(message.id) ?? null`.

**Constitution selector** (`ChatFormConstitutionSelector.svelte`) calls `chatStore.setConstitution(name, content)`, which injects the `<CONSTITUTION>` system message and sets `activePersonalityName`.

**SERVER_ROLE detection**: `server.svelte.ts` checks the `/props` endpoint on load. In ROUTER mode the model selector is shown; in MODEL mode it's hidden and a single model is always active.
