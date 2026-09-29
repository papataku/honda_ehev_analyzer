from __future__ import annotations
from dataclasses import dataclass
from datetime import timedelta
from typing import Iterable
from .base import RawChunk

@dataclass(frozen=True)
class Fault:
    kind: str
    index: int = 0
    value: float|int|str|None = None

class FaultInjector:
    """Deterministic replay fault injection. Faults are indexed by input chunk."""
    def __init__(self, faults: Iterable[Fault]=()): self.faults=list(faults)
    def apply(self, rows):
        out=[]
        by={}
        for f in self.faults: by.setdefault(f.index,[]).append(f)
        for i,row in enumerate(rows):
            ts,layer,source,payload=row; chunks=[(ts,layer,source,bytes(payload))]
            for f in by.get(i,[]):
                if f.kind in ('drop','ble_notification_drop','isotp_cf_drop'): chunks=[]
                elif f.kind=='duplicate': chunks=chunks+chunks
                elif f.kind=='split' and chunks:
                    n=int(f.value or max(1,len(payload)//2)); p=chunks[0][3]
                    chunks=[(ts,layer,source,p[:n]),(ts,layer,source,p[n:])]
                elif f.kind=='delay':
                    sec=float(f.value or 1); chunks=[((__import__('datetime').datetime.fromisoformat(x[0])+timedelta(seconds=sec)).isoformat(),x[1],x[2],x[3]) for x in chunks]
                elif f.kind=='elm_no_data': chunks=[(ts,layer,source,b'NO DATA\r>')]
                elif f.kind=='bus_error': chunks=[(ts,layer,source,b'BUS ERROR\r>')]
                elif f.kind=='timeout': chunks=[]
                elif f.kind=='corrupt_sequence' and chunks:
                    p=bytearray(chunks[0][3]);
                    if p: p[0]^=1
                    chunks=[(ts,layer,source,bytes(p))]
            out.extend(chunks)
        # Merge is deliberately explicit: merge this row with the previous emitted row.
        for f in sorted((x for x in self.faults if x.kind=='merge'),key=lambda x:x.index,reverse=True):
            if 0 < f.index < len(out):
                a,b=out[f.index-1],out[f.index]; out[f.index-1]=(b[0],b[1],b[2],a[3]+b[3]); del out[f.index]
        return out
