from dataclasses import dataclass

@dataclass(frozen=True)
class ElmResponse:
    raw: bytes
    text: str

class ElmPromptFramer:
    """Reassembles arbitrarily split/merged BLE notifications until ELM prompt '>'."""
    def __init__(self): self._buf = bytearray()
    def feed(self, chunk: bytes) -> list[ElmResponse]:
        self._buf.extend(chunk)
        out = []
        while True:
            try: idx = self._buf.index(ord('>'))
            except ValueError: break
            raw = bytes(self._buf[:idx+1]); del self._buf[:idx+1]
            out.append(ElmResponse(raw, raw.decode('ascii', errors='replace')))
        return out
    @property
    def pending(self): return bytes(self._buf)
