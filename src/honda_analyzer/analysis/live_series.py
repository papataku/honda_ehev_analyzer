from __future__ import annotations
from collections import deque
from dataclasses import dataclass

@dataclass(frozen=True)
class Sample:
    t: float
    value: float

class LiveSeriesBuffer:
    """Bounded numeric time-series buffer. Raw protocol evidence remains in SQLite."""
    def __init__(self, max_seconds: float = 300.0, max_points: int = 12000):
        self.max_seconds=float(max_seconds); self.samples=deque(maxlen=max_points)
    def append(self,t:float,value:float):
        self.samples.append(Sample(float(t),float(value))); self.trim(t)
    def trim(self,now:float):
        cutoff=float(now)-self.max_seconds
        while self.samples and self.samples[0].t < cutoff:self.samples.popleft()
    def arrays(self):
        return [x.t for x in self.samples],[x.value for x in self.samples]
    def between(self,start:float,end:float):
        return [x for x in self.samples if start <= x.t <= end]

def numeric_value(value):
    if value is None or isinstance(value,bool): return None
    if isinstance(value,(int,float)): return float(value)
    return None
