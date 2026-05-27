from pydantic_settings import BaseSettings, SettingsConfigDict
from typing import Optional

class EnvSettings(BaseSettings):
    huggingface_api_key: Optional[str] = None  # Hugging Face API key for accessing private models and datasets
    wandb_api_key: Optional[str] = None      # Weights & Biases tracking
    
    model_config = SettingsConfigDict(env_file=".env", extra="ignore")

env_settings = EnvSettings()