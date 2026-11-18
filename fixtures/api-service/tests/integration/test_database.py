"""The integration stage's Postgres service container is there and usable."""

from __future__ import annotations

import asyncio
import os

import asyncpg


async def _distance(url: str) -> float:
    conn = await asyncpg.connect(url)
    try:
        # pgvector, which the fleet's image carries and its migrations use.
        await conn.execute("CREATE EXTENSION IF NOT EXISTS vector")
        await conn.execute("CREATE TEMP TABLE probe (id int PRIMARY KEY, v vector(3))")
        await conn.execute("INSERT INTO probe VALUES (1, '[1,2,3]')")
        distance = await conn.fetchval("SELECT v <-> '[1,2,4]' FROM probe WHERE id = 1")
    finally:
        await conn.close()
    return float(distance)


def test_both_addresses_name_the_same_database(database_url: str) -> None:
    assert os.environ.get("DATABASE_URL") == database_url


def test_the_database_stores_and_queries_vectors(database_url: str) -> None:
    assert asyncio.run(_distance(database_url)) == 1.0
