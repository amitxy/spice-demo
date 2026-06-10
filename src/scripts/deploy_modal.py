"""
Deploy the full spice-demo image to Modal (modal.com) as an on-demand demo.

This runs the SAME public Docker image used everywhere else
(`ghcr.io/amitxy/spice-demo:latest`) — both GGUF models baked in at /app/models and
the SvelteKit UI + OpenAI-compatible API served by a CUDA `llama-server` on :8000.
Modal pulls the image, runs it on an A10G GPU, and gives it a public URL. It scales to
zero 120 s after the last request, so it costs nothing while idle (no warm-up, not 24/7).

Unlike the other scripts in src/scripts/ (run as `python -m src.scripts.X`), a Modal
app is driven by the `modal` CLI:

    # one-time, on a fresh account:
    uv add modal            # (or: pip install modal)
    modal token new         # browser auth for the CLI

    # dev: temporary URL, hot-reloads on edit
    modal serve src/scripts/deploy_modal.py

    # persistent deploy: stable URL like
    #   https://<workspace>--spice-demo-serve.modal.run
    modal deploy src/scripts/deploy_modal.py

Smoke test once it prints a *.modal.run URL (first call is slow — cold start + model
load; later calls are fast):

    curl <url>/health          # {"status":"ok"}
    curl <url>/v1/models       # spice-finetuned, qwen3.5-9b-base
    curl <url>/v1/chat/completions -H 'Content-Type: application/json' \
        -d '{"model":"spice-finetuned","messages":[{"role":"user","content":"hi"}]}'

Notes on the design:
  * No Modal Volume. The full image already bakes the models into /app/models, so there
    is nothing to download at runtime (the reference snippet's /models volume only made
    sense for the slim, no-models image variant).
  * Modal ignores the image's ENTRYPOINT, so we launch llama-server ourselves below,
    mirroring docker/entrypoint.sh minus the cloudflared tunnel (Modal supplies the URL).
  * The A10G is sm_86, which matches one of the image's baked CUDA arches (80;86;89).
    A T4 (sm_75) would NOT work with this prebuilt binary.
"""

import json
import subprocess

import modal

IMAGE = "ghcr.io/amitxy/spice-demo:latest"
PORT = 8000

app = modal.App("spice-demo")

# Public image -> no registry secret needed. Two Modal-specific adjustments:
#   * add_python: the image only has `python3` (no bare `python`), so Modal can't detect
#     its interpreter; this layers in a standalone Python Modal uses to run the function.
#     Harmless here -- llama-server is a binary and the config read works under any Python.
#   * entrypoint([]): clear the image's `tini -> entrypoint.sh` ENTRYPOINT, otherwise it
#     runs on container start (cloudflared + its own server launch) and fights Modal's
#     runtime. We launch llama-server ourselves in serve() instead.
image = modal.Image.from_registry(IMAGE, add_python="3.11").entrypoint([])


@app.function(
    image=image,
    gpu="A10G",
    scaledown_window=120,  # stop the container 120 s after the last request (scale to zero)
    max_containers=1,      # single replica — a demo; avoid surprise horizontal fan-out cost
    timeout=600,           # generous per-request ceiling for long generations
)
@modal.concurrent(max_inputs=10)  # let the one container serve many concurrent HTTP requests
@modal.web_server(port=PORT, startup_timeout=300)
def serve():
    """Start llama-server and let Modal proxy the whole thing (UI + API) on PORT.

    Popen is non-blocking on purpose: this function must return so Modal can poll the
    port and, once it's listening, forward public traffic to it. In router mode
    (--models-max 1) the port binds immediately and the model loads lazily on the first
    request, so startup is fast and only the first inference pays the model-load cost.
    The subprocess inherits the image's environment (incl. LD_LIBRARY_PATH=/app/bin, so
    the binary finds its bundled libggml*/libllama shared libs).
    """
    # Same server-wide thinking_prefix wiring the host run command and entrypoint use.
    kwargs = json.dumps(json.load(open("/app/inference-config.json")))

    subprocess.Popen(
        [
            "/app/bin/llama-server",
            "--models-dir", "/app/models",
            "--models-max", "1",
            "--jinja", "--chat-template-file", "/app/chat_template.jinja",
            "--chat-template-kwargs", kwargs,
            "--host", "0.0.0.0", "--port", str(PORT),
            "--n-gpu-layers", "999",
            "--ctx-size", "32768", "--parallel", "2", "--cont-batching",
            "--reasoning-format", "deepseek", "--reasoning", "on",
        ]
    )
