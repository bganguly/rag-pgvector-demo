import asyncio

import asyncpg
from langchain_openai import OpenAIEmbeddings
from langchain_postgres import PGVector

from app.config import settings

_pool: asyncpg.Pool | None = None
_vector_store: PGVector | None = None


async def get_pool() -> asyncpg.Pool:
    global _pool
    if _pool is None:
        _pool = await asyncpg.create_pool(
            settings.database_url,
            min_size=0,
            max_inactive_connection_lifetime=30,
        )
    return _pool


def get_vector_store() -> PGVector:
    global _vector_store
    if _vector_store is None:
        embeddings = OpenAIEmbeddings(
            model="text-embedding-3-small",
            openai_api_key=settings.openai_api_key,
        )
        _vector_store = PGVector(
            embeddings=embeddings,
            collection_name="documents",
            connection=settings.pgvector_connection,
            use_jsonb=True,
        )
    return _vector_store


async def init_db() -> None:
    global _pool
    last_err: Exception | None = None
    for attempt in range(3):
        try:
            pool = await get_pool()
            async with pool.acquire() as conn:
                await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
            get_vector_store().create_collection()
            return
        except Exception as e:
            last_err = e
            _pool = None  # force fresh pool on next attempt
            if attempt < 2:
                await asyncio.sleep(3)
    raise last_err  # type: ignore[misc]
