from __future__ import annotations
from abc import ABC, abstractmethod
from dataclasses import dataclass
from datetime import datetime, timezone

@dataclass(frozen=True)
class RawChunk:
    data: bytes
    source: str
    timestamp: datetime

    @classmethod
    def now(cls, data: bytes, source: str) -> "RawChunk":
        return cls(data=data, source=source, timestamp=datetime.now(timezone.utc))

class Transport(ABC):
    @abstractmethod
    async def connect(self) -> None: ...
    @abstractmethod
    async def disconnect(self) -> None: ...
    @abstractmethod
    async def write(self, data: bytes) -> None: ...
    @abstractmethod
    async def recv(self) -> RawChunk: ...
