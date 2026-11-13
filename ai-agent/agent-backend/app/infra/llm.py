import logging
import os
from dotenv import load_dotenv
from langchain_openai import ChatOpenAI

load_dotenv()

logger = logging.getLogger(__name__)

# Determine LLM Provider
# Supported: "meshapi", "openrouter", "openai"
provider = os.getenv("LLM_PROVIDER")
if not provider:
    if os.getenv("MESH_API_KEY"):
        provider = "meshapi"
    elif os.getenv("OPENROUTER_API_KEY"):
        provider = "openrouter"
    else:
        provider = "meshapi"

LLM_PROVIDER = provider.lower()
logger.info(f"Using LLM provider: {LLM_PROVIDER}")

if LLM_PROVIDER == "meshapi":
    BASE_URL = os.getenv("MESH_BASE_URL") or os.getenv("OPENAI_BASE_URL") or "https://api.meshapi.ai/v1"
    API_KEY = os.getenv("MESH_API_KEY") or os.getenv("OPENAI_API_KEY")
    DEFAULT_MODEL = os.getenv("MESH_MODEL", "openai/gpt-4o-mini")
elif LLM_PROVIDER == "openrouter":
    BASE_URL = os.getenv("OPENROUTER_BASE_URL") or "https://openrouter.ai/api/v1"
    API_KEY = os.getenv("OPENROUTER_API_KEY")
    DEFAULT_MODEL = os.getenv("OPENROUTER_MODEL", "openai/gpt-4o-mini")
else:  # generic openai or custom endpoint
    BASE_URL = os.getenv("OPENAI_BASE_URL", "https://api.openai.com/v1")
    API_KEY = os.getenv("OPENAI_API_KEY")
    DEFAULT_MODEL = os.getenv("OPENAI_MODEL", "gpt-4o-mini")

DIAGNOSTICS_MODEL_ID = os.getenv("DIAGNOSTICS_MODEL_ID") or DEFAULT_MODEL
REMEDIATION_MODEL_ID = os.getenv("REMEDIATION_MODEL_ID") or DEFAULT_MODEL

def check_llm_ready() -> None:
    if not API_KEY:
        raise ValueError(f"API key not configured for LLM provider '{LLM_PROVIDER}'")

def get_diagnostics_model():
    return ChatOpenAI(
        model=DIAGNOSTICS_MODEL_ID,
        base_url=BASE_URL,
        api_key=API_KEY,
        temperature=0.0,
    )

def get_remediation_model():
    return ChatOpenAI(
        model=REMEDIATION_MODEL_ID,
        base_url=BASE_URL,
        api_key=API_KEY,
        temperature=0.2,
    )

