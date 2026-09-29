from __future__ import annotations
from dataclasses import dataclass, asdict
from .timing import timing_stats

@dataclass(frozen=True)
class CommunicationQuality:
    grade: str
    score: int
    stats: dict
    rssi_dbm: int | None
    timeout_rate: float
    error_rate: float
    evidence: tuple[str, ...]
    recommendations: tuple[str, ...]

    def to_dict(self): return asdict(self)

def assess_communication_quality(latencies_ms, *, rssi_dbm=None, timeouts=0, errors=0, total_requests=None, duration_s=None, notifications=0, byte_count=0):
    vals=[float(x) for x in latencies_ms]
    total=int(total_requests if total_requests is not None else len(vals)+timeouts+errors)
    timeout_rate=timeouts/total if total else 0.0; error_rate=errors/total if total else 0.0
    st=timing_stats(vals,duration_s,notifications,byte_count)
    if total == 0:
        return CommunicationQuality('NO DATA',0,st,rssi_dbm,0.0,0.0,('No requests recorded yet',),('Collect a short stationary communication sample before judging link quality.',))
    score=100; ev=[]; rec=[]
    p95=st.get('p95_ms')
    if p95 is not None:
        ev.append(f'p95 latency {p95:.1f} ms')
        if p95>1000: score-=35; rec.append('Reduce polling rate; p95 latency exceeds 1 s.')
        elif p95>500: score-=20; rec.append('Use a conservative poll schedule; p95 latency exceeds 500 ms.')
        elif p95>250: score-=8
    if timeout_rate:
        ev.append(f'timeout rate {timeout_rate:.1%}')
        if timeout_rate>0.10: score-=35
        elif timeout_rate>0.02: score-=18
        else: score-=5
        rec.append('Investigate adapter load, BLE link quality, and request cadence before driving tests.')
    if error_rate:
        ev.append(f'error rate {error_rate:.1%}'); score-=min(30,max(5,round(error_rate*100)))
    if rssi_dbm is not None:
        ev.append(f'BLE RSSI {rssi_dbm} dBm')
        if rssi_dbm<-85: score-=25; rec.append('Move the Mac/adapter closer or remove RF obstruction; BLE RSSI is weak.')
        elif rssi_dbm<-75: score-=10
    else: ev.append('BLE RSSI unavailable')
    score=max(0,min(100,int(score))); grade='GOOD' if score>=85 else 'FAIR' if score>=65 else 'POOR'
    return CommunicationQuality(grade,score,st,rssi_dbm,timeout_rate,error_rate,tuple(ev),tuple(dict.fromkeys(rec)))
