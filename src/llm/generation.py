import subprocess

import litellm
from litellm.router import Router
from litellm.llms.custom_llm import CustomLLM
from litellm import ModelResponse

_MODEL = "agy/gemini-3.5-flash(medium)"

class _AgyCLIProvider(CustomLLM):
    def completion(
        self,
        model: str,
        messages: list,
        *args,
        **kwargs,
    ) -> ModelResponse:
        system_prompt = next((m["content"] for m in messages if m["role"] == "system"), "")
        user_prompt = messages[-1]["content"]
        # TODO: handle system prompt properly
        tmp_path = r"C:\\Users\\Amit\\.gemini\\antigravity-cli\\scratch\\temp.txt"
        full_prompt = (f"{system_prompt}\n\n{user_prompt}" if system_prompt else user_prompt) + f"\nWrite you answer in: {tmp_path}"

        result = subprocess.run(
            ["agy", "-p", full_prompt],
            capture_output=True,
            text=True,
        )
        
        
        output = ''
        with open(tmp_path, "r", encoding="utf-8") as f:
            output = f.read().strip()
        
        # if result.returncode != 0:
        #     raise RuntimeError(f"agy CLI error: {result.stderr.strip()}")
        return ModelResponse(
            model=model,
            choices=[{"message": {"role": "assistant", "content": output}}],
        )


litellm.custom_provider_map = [
    {"provider": "agy", "custom_handler": _AgyCLIProvider()}
]



def generate_response(constitution: str, query: str) -> str:
    response = litellm.completion(
        model=_MODEL,
        messages=[
            {"role": "system", "content": f"<CONSTITUTION>\n{constitution}\n</CONSTITUTION>"},
            {"role": "user", "content": query},
        ],
    )
    choices = response.get("choices", []) if isinstance(response, dict) else getattr(response, "choices", [])

    if not choices:
        raise RuntimeError("Model returned no textual content")

    return choices[0].message.content
