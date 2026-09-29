import asyncio
from .base import Transport, RawChunk

class MockTransport(Transport):
    def __init__(self, chunks=()):
        self.rx = asyncio.Queue()
        self.tx = []
        self.connected = False
        for chunk in chunks:
            self.rx.put_nowait(RawChunk.now(chunk, "mock"))
    async def connect(self): self.connected = True
    async def disconnect(self): self.connected = False
    async def write(self, data: bytes): self.tx.append(bytes(data))
    async def recv(self): return await self.rx.get()
    def feed(self, data: bytes): self.rx.put_nowait(RawChunk.now(data, "mock"))
