"""Runtime settings for the Phase 1A RAG API."""

from functools import lru_cache

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    """Environment-backed application settings.

    Secrets are intentionally absent. Azure service authentication uses the
    Function App system-assigned managed identity through DefaultAzureCredential.
    """

    model_config = SettingsConfigDict(extra="ignore", case_sensitive=False)

    azure_openai_endpoint: str = Field(alias="AZURE_OPENAI_ENDPOINT")
    azure_openai_chat_deployment: str = Field(
        default="chat-bht-insight", alias="AZURE_OPENAI_CHAT_DEPLOYMENT"
    )
    azure_openai_embedding_deployment: str = Field(
        default="embed-bht-insight", alias="AZURE_OPENAI_EMBEDDING_DEPLOYMENT"
    )
    azure_openai_api_version: str = Field(
        default="2024-10-21", alias="AZURE_OPENAI_API_VERSION"
    )
    azure_search_endpoint: str = Field(alias="AZURE_SEARCH_ENDPOINT")
    azure_search_index: str = Field(default="bht-insight-chunks", alias="AZURE_SEARCH_INDEX")
    retrieval_top_k: int = Field(default=5, ge=1, le=10, alias="RAG_RETRIEVAL_TOP_K")


@lru_cache
def get_settings() -> Settings:
    """Return cached runtime settings."""

    return Settings()  # pyright: ignore[reportCallIssue]
