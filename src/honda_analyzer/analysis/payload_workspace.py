from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime, timezone
from collections import Counter
import math
import statistics
from .payload_diff import elm_command_payload, activity_matrix
from .fields import expand_fields

@dataclass(frozen=True)
class TimedPayload:
    elapsed_s: float
    timestamp: str
    payload: bytes

@dataclass(frozen=True)
class ByteDistributionDiff:
    """Robust A/B statistics for one byte offset.

    `distribution_distance` is total-variation distance between the two observed
    byte-value distributions. 0.0 means identical observed distributions and
    1.0 means they do not overlap at all. This is descriptive evidence, not a
    claim about signal semantics.
    """
    offset: int
    a_median: float | None
    b_median: float | None
    a_mean: float | None
    b_mean: float | None
    a_min: int | None
    a_max: int | None
    b_min: int | None
    b_max: int | None
    a_change_ratio: float
    b_change_ratio: float
    distribution_distance: float
    changed: bool

    # Backward-compatible names used by older tests/UI code.
    @property
    def a(self):
        return self.a_median

    @property
    def b(self):
        return self.b_median


def command_payloads(rows, command: str, session_started: str, start_s: float, end_s: float) -> list[TimedPayload]:
    """Extract visualization payloads for one immutable command range."""
    base=datetime.fromisoformat(session_started)
    if base.tzinfo is None: base=base.replace(tzinfo=timezone.utc)
    out=[]
    for ts, cmd, raw, latency, success in rows:
        if str(cmd).replace(' ','').upper()!=command.replace(' ','').upper() or not success:
            continue
        dt=datetime.fromisoformat(ts)
        if dt.tzinfo is None: dt=dt.replace(tzinfo=timezone.utc)
        elapsed=(dt-base).total_seconds()
        if start_s <= elapsed <= end_s:
            p=elm_command_payload(raw or b'',command)
            if p: out.append(TimedPayload(elapsed,ts,p))
    return out


def _values(samples:list[TimedPayload], offset:int) -> list[int]:
    return [s.payload[offset] for s in samples if offset < len(s.payload)]


def _change_ratio(values:list[int]) -> float:
    if len(values) < 2:
        return 0.0
    return sum(a != b for a,b in zip(values, values[1:])) / (len(values)-1)


def _tv_distance(a:list[int], b:list[int]) -> float:
    if not a or not b:
        return 1.0 if a or b else 0.0
    ca,cb=Counter(a),Counter(b); na,nb=len(a),len(b)
    keys=set(ca)|set(cb)
    return 0.5*sum(abs(ca[k]/na-cb[k]/nb) for k in keys)


def median_payload(samples:list[TimedPayload])->bytes:
    """Construct a byte-wise median payload for display/field expansion only.

    This avoids choosing an arbitrary 'most common whole payload' when every
    payload is unique. It is a visualization summary, never raw evidence.
    """
    if not samples:return b''
    width=max(len(x.payload) for x in samples)
    out=[]
    for i in range(width):
        vals=_values(samples,i)
        out.append(int(round(statistics.median(vals))) if vals else 0)
    return bytes(out)


def mode_payload(samples:list[TimedPayload])->bytes:
    """Legacy helper retained for compatibility; prefer median_payload()."""
    if not samples:return b''
    return Counter(x.payload for x in samples).most_common(1)[0][0]


def differential(samples_a:list[TimedPayload], samples_b:list[TimedPayload]) -> list[ByteDistributionDiff]:
    width=max([len(x.payload) for x in samples_a+samples_b] or [0])
    out=[]
    for i in range(width):
        a=_values(samples_a,i); b=_values(samples_b,i)
        am=float(statistics.median(a)) if a else None
        bm=float(statistics.median(b)) if b else None
        amean=float(statistics.fmean(a)) if a else None
        bmean=float(statistics.fmean(b)) if b else None
        dist=_tv_distance(a,b)
        # 'changed' means the observed distributions differ materially at all;
        # it does not imply a decoded signal or causality.
        changed=(a != b) and (am != bm or (min(a) if a else None)!=(min(b) if b else None) or (max(a) if a else None)!=(max(b) if b else None) or dist>0.0)
        out.append(ByteDistributionDiff(
            i,am,bm,amean,bmean,
            min(a) if a else None,max(a) if a else None,
            min(b) if b else None,max(b) if b else None,
            _change_ratio(a),_change_ratio(b),dist,changed,
        ))
    return out


def heatmap_data(samples:list[TimedPayload]):
    """Return rectangular byte matrix; -1 denotes a missing byte."""
    if not samples:return [],[],[]
    width=max(len(x.payload) for x in samples)
    matrix=[]
    for s in samples: matrix.append([s.payload[i] if i<len(s.payload) else -1 for i in range(width)])
    return [s.elapsed_s for s in samples],list(range(width)),matrix


def activity(samples:list[TimedPayload]):
    return activity_matrix([x.payload for x in samples])


def expanded_candidates(samples:list[TimedPayload], offset:int|None=None):
    p=median_payload(samples)
    vals=expand_fields(p)
    if offset is not None: vals=[x for x in vals if x[0]==offset]
    return vals
