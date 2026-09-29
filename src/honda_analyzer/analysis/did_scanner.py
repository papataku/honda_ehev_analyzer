from dataclasses import dataclass
from enum import Enum
from typing import Protocol, Callable
import time
from honda_analyzer.protocol.uds import safe_scan_request, parse_22_response

class ScanStatus(str, Enum):
    NOT_SCANNED='not_scanned'; COMPLETED='completed'; POSITIVE='positive'; NRC='nrc'; TIMEOUT='timeout'; PAUSED='paused'; STOPPED_SPEED='stopped_speed'

@dataclass(frozen=True)
class ScanResult:
    ecu: str; did: int; status: ScanStatus; latency_ms: float | None=None; nrc: int | None=None; payload: bytes=b''; response_can_id: str | None=None

class Uds22Client(Protocol):
    def read_did(self, ecu: str, request: bytes) -> tuple[bytes,str|None]: ...

class DidScanner:
    """Read-only UDS 0x22 scanner. No generic service API exists here by design."""
    def __init__(self, client: Uds22Client, persist: Callable[[ScanResult],None], speed_kph: Callable[[],float|None]|None=None):
        self.client=client; self.persist=persist; self.speed_kph=speed_kph or (lambda: None); self.paused=False; self.stopped=False
    def pause(self): self.paused=True
    def resume(self): self.paused=False
    def stop(self): self.stopped=True
    def scan(self, ecu: str, start: int, end: int, rate_hz: float=2.0, completed: set[int]|None=None):
        if not (0<=start<=end<=0xffff): raise ValueError('invalid DID range')
        if rate_hz <= 0: raise ValueError('rate_hz must be > 0')
        completed=completed or set(); period=1.0/rate_hz
        for did in range(start,end+1):
            if did in completed: continue
            if self.stopped: break
            if self.paused: break
            speed=self.speed_kph()
            if speed is not None and speed > 0:
                r=ScanResult(ecu,did,ScanStatus.STOPPED_SPEED); self.persist(r); yield r; break
            t=time.monotonic()
            try:
                payload,can_id=self.client.read_did(ecu,safe_scan_request(did))
                latency=(time.monotonic()-t)*1000
                parsed=parse_22_response(payload)
                r=ScanResult(ecu,did,ScanStatus.POSITIVE if parsed.positive else ScanStatus.NRC,latency,parsed.nrc,parsed.payload,can_id)
            except TimeoutError:
                r=ScanResult(ecu,did,ScanStatus.TIMEOUT,(time.monotonic()-t)*1000)
            self.persist(r); yield r
            remain=period-(time.monotonic()-t)
            if remain>0: time.sleep(remain)
