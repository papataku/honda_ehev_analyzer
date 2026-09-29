from __future__ import annotations
from dataclasses import dataclass
import math
from .correlation import pearson, spearman, stats
from .fields import expand_fields
from .candidates import motor_rpm_candidate

@dataclass(frozen=True)
class CorrelationResult:
    interpretation: str
    reference: str
    samples: int
    pearson: float
    spearman: float
    best_lag_s: float | None
    best_lag_r: float | None
    candidate_score: float | None
    evidence: tuple[str,...]
    contradictions: tuple[str,...]
    field_stats: object | None


def field_value(payload: bytes, offset: int, interpretation: str):
    for off,name,value in expand_fields(payload):
        if off == offset and name == interpretation:
            return float(value)
    return None


def field_series(samples, offset: int, interpretation: str):
    out=[]
    for s in samples:
        v=field_value(s.payload,offset,interpretation)
        if v is not None: out.append((float(s.elapsed_s),v))
    return out


def _nearest(series, t, tolerance):
    if not series:return None
    best=min(series,key=lambda x:abs(x[0]-t))
    return best[1] if abs(best[0]-t)<=tolerance else None


def align_nearest(candidate, reference, tolerance_s=0.75, lag_s=0.0):
    """Align asynchronous polling by timestamp without modifying source timestamps."""
    a=[];b=[];times=[]
    for t,v in candidate:
        rv=_nearest(reference,t+lag_s,tolerance_s)
        if rv is not None and math.isfinite(v) and math.isfinite(rv):
            times.append(t);a.append(float(v));b.append(float(rv))
    return times,a,b


def best_lag(candidate, reference, max_lag_s=5.0, step_s=0.1, tolerance_s=0.75):
    best=None
    steps=int(round(max_lag_s/step_s))
    for i in range(-steps,steps+1):
        lag=i*step_s; _,a,b=align_nearest(candidate,reference,tolerance_s,lag)
        if len(a)<3:continue
        r=pearson(a,b)
        if r==r and (best is None or abs(r)>abs(best[1])):best=(lag,r,len(a))
    return best


def analyze_field(samples, offset, interpretation, reference_name, reference_series, *, speed_series=None, engine_series=None, tolerance_s=0.75):
    candidate=field_series(samples,offset,interpretation)
    _,a,b=align_nearest(candidate,reference_series,tolerance_s)
    pr=pearson(a,b) if len(a)>=2 else float('nan'); sr=spearman(a,b) if len(a)>=2 else float('nan')
    lag=best_lag(candidate,reference_series,tolerance_s=tolerance_s)
    score=None;evidence=();contradictions=()
    if speed_series is not None and engine_series is not None:
        # Candidate scoring uses only timestamps where field, speed and engine RPM all have nearby samples.
        f=[];sp=[];en=[]
        for t,v in candidate:
            sv=_nearest(speed_series,t,tolerance_s); ev=_nearest(engine_series,t,tolerance_s)
            if sv is not None and ev is not None:f.append(v);sp.append(sv);en.append(ev)
        if len(f)>=3:
            c=motor_rpm_candidate(f,sp,en);score=c.score;evidence=c.evidence;contradictions=c.contradictions
    return CorrelationResult(interpretation,reference_name,len(a),pr,sr,None if lag is None else lag[0],None if lag is None else lag[1],score,evidence,contradictions,stats([v for _,v in candidate]) if candidate else None)
