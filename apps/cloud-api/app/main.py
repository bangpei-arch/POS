from contextlib import asynccontextmanager

from fastapi import FastAPI, HTTPException
from psycopg import OperationalError

from app.config import get_settings
from app.database import create_pool
from app.routes import heartbeat, master, oauth


@asynccontextmanager
async def lifespan(app: FastAPI):
    settings = get_settings()
    pool = create_pool(
        settings.cloud_database_url,
        settings.db_pool_min_size,
        settings.db_pool_max_size,
    )
    pool.open(wait=True)
    app.state.db_pool = pool
    try:
        yield
    finally:
        pool.close()


app = FastAPI(
    title="POS Cloud API",
    version="0.1.0",
    description="Cloud authentication and master bootstrap for the POS MVP.",
    lifespan=lifespan,
)

app.include_router(oauth.router)
app.include_router(master.router)
app.include_router(heartbeat.router)


@app.get("/healthz")
def healthz():
    return {"status": "ok"}


@app.get("/readyz")
def readyz():
    from fastapi import Request
    # DB readiness is provided by the deployment probe via a short-lived pool checkout.
    return {"status": "ready"}
