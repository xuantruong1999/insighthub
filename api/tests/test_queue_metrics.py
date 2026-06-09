import pytest

from app.core.metrics import ingestion_queue_depth
from app.core.queue_metrics import refresh_queue_depth


class FakeRedis:
    def __init__(self, n):
        self._n = n

    async def zcard(self, key):
        assert key == "arq:queue"
        return self._n


@pytest.mark.asyncio
async def test_refresh_sets_gauge_from_zcard():
    await refresh_queue_depth(FakeRedis(7))
    assert ingestion_queue_depth._value.get() == 7


@pytest.mark.asyncio
async def test_refresh_on_error_sets_zero():
    class Broken:
        async def zcard(self, key):
            raise RuntimeError("redis down")

    await refresh_queue_depth(Broken())
    assert ingestion_queue_depth._value.get() == 0
