from functools import lru_cache
from pathlib import Path

from pydantic import Field
from pydantic_settings import BaseSettings, SettingsConfigDict


class Settings(BaseSettings):
    model_config = SettingsConfigDict(env_file=".env", env_prefix="", extra="ignore")

    cloud_database_url: str = Field(alias="CLOUD_DATABASE_URL")
    jwt_private_key_path: Path = Field(alias="JWT_PRIVATE_KEY_PATH")
    jwt_public_key_path: Path = Field(alias="JWT_PUBLIC_KEY_PATH")
    jwt_kid: str = Field(default="cloud-rsa-2026-01", alias="JWT_KID")
    jwt_issuer: str = Field(default="pos-cloud", alias="JWT_ISSUER")
    jwt_audience: str = Field(default="pos-cloud-api", alias="JWT_AUDIENCE")
    token_ttl_seconds: int = Field(default=300, alias="TOKEN_TTL_SECONDS")
    db_pool_min_size: int = Field(default=1, alias="DB_POOL_MIN_SIZE")
    db_pool_max_size: int = Field(default=10, alias="DB_POOL_MAX_SIZE")


@lru_cache
def get_settings() -> Settings:
    return Settings()
