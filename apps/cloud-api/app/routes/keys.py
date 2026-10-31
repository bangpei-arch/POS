import json

from fastapi import APIRouter
import jwt
from cryptography.hazmat.primitives import serialization

from app.config import get_settings

router = APIRouter()


@router.get("/.well-known/jwks.json")
def jwks():
    settings = get_settings()
    public_key = settings.jwt_public_key_path.read_text(encoding="utf-8")
    public_key_object = serialization.load_pem_public_key(public_key.encode("utf-8"))
    key = json.loads(jwt.algorithms.RSAAlgorithm.to_jwk(public_key_object))
    key.update({"kid": settings.jwt_kid, "use": "sig", "alg": "RS256"})
    return {"keys": [key]}
