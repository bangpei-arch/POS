from functools import lru_cache
from uuid import UUID

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="", extra="ignore")

    store_database_url: str = Field(alias="STORE_DATABASE_URL")
    store_id: UUID = Field(alias="STORE_ID")
    store_node_id: UUID = Field(alias="STORE_NODE_ID")
    store_node_code: str = Field(alias="STORE_NODE_CODE")
    terminal_id: UUID = Field(alias="TERMINAL_ID")
    store_jwt_secret: str = Field(alias="STORE_JWT_SECRET")
    store_jwt_ttl_seconds: int = Field(default=28800, alias="STORE_JWT_TTL_SECONDS")
    cloud_api_base_url: str = Field(default="", alias="CLOUD_API_BASE_URL")
    cloud_client_id: str = Field(default="", alias="CLOUD_CLIENT_ID")
    cloud_client_secret: str = Field(default="", alias="CLOUD_CLIENT_SECRET")
    db_pool_min_size: int = Field(default=1, alias="DB_POOL_MIN_SIZE")
    db_pool_max_size: int = Field(default=10, alias="DB_POOL_MAX_SIZE")


@lru_cache
def get_settings() -> Settings:
    settings = Settings()
    if len(settings.store_jwt_secret.encode("utf-8")) < 32:
        raise ValueError("STORE_JWT_SECRET must contain at least 32 bytes")
    return settings
