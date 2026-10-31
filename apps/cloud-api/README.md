# POS Cloud API — MVP M1

Cloud API tahap pertama menyediakan:
- OAuth2 Client Credentials token endpoint (HTTP Basic over HTTPS).
- RS256 JWT access token, TTL 5 menit.
- Token verification dengan issuer, audience, signature, expiry, node status, dan credential version.
- Master bootstrap snapshot untuk produk, harga aktif, metode pembayaran, dan metadata toko.
- Store server heartbeat.
- PostgreSQL connection pool.

Belum termasuk event receiver, reporting endpoint, store API, sender worker, atau UI.

## Development

1. Buat cloud database PostgreSQL 16.
2. Terapkan migration cloud: lihat ../../database/cloud-migrations/README.md.
3. Buat RSA development keypair:
   `bash apps/cloud-api/scripts/generate-dev-jwt-keys.sh`
4. Salin .env.example menjadi .env dan sesuaikan DSN/key path.
5. Buat credential Argon2id untuk client secret melalui provisioning admin tool (belum tersedia pada M1); jangan menyimpan secret plaintext di database.
6. Jalankan:

   ```bash
   cd apps/cloud-api
   python -m venv .venv
   source .venv/bin/activate
   pip install -r requirements.txt
   uvicorn app.main:app --reload
   ```

OpenAPI docs: http://localhost:8000/docs

## Operational notes

- Expose only behind HTTPS reverse proxy.
- Keep private key in a secret manager/KMS in production.
- Do not commit .env, JWT keys, or client secrets.
- Production must provision client_secret_hash using Argon2id and keep the generated secret only at the store server.
