from __future__ import annotations

from bisect import bisect_left
from dataclasses import dataclass
from datetime import datetime
import math
from typing import Iterable


@dataclass(frozen=True)
class DidInventoryItem:
    ecu: str
    did: int
    payload: bytes
    response_can_id: str | None
    discovered_session_id: int | None = None


@dataclass(frozen=True)
class DidCoverage:
    ecu: str
    did: int
    samples: int
    unique_payloads: int
    payload_length_min: int
    payload_length_max: int


@dataclass(frozen=True)
class DidFieldRank:
    ecu: str
    did: int
    field: str
    samples: int
    changing_ratio: float
    corr_speed_ev: float | None
    corr_speed_all: float | None
    corr_hv_power: float | None
    corr_hv_current: float | None
    corr_soc: float | None
    corr_engine_rpm: float | None
    motor_score: float
    priority_score: float
    note: str


def _parse_ts(s: str) -> float:
    return datetime.fromisoformat(s.replace('Z', '+00:00')).timestamp()


def coverage_from_rows(rows: Iterable[tuple]) -> list[DidCoverage]:
    grouped: dict[tuple[str, int], list[bytes]] = {}
    for row in rows:
        if len(row) < 4: continue
        _ts, ecu, did, payload = row[:4]
        grouped.setdefault((str(ecu).upper(), int(did)), []).append(bytes(payload or b''))
    out=[]
    for (ecu,did), payloads in sorted(grouped.items()):
        lengths=[len(x) for x in payloads]
        out.append(DidCoverage(ecu,did,len(payloads),len(set(payloads)),min(lengths),max(lengths)))
    return out


def _pearson(xs: list[float], ys: list[float]) -> float | None:
    if len(xs) < 5 or len(xs) != len(ys): return None
    mx=sum(xs)/len(xs); my=sum(ys)/len(ys)
    dx=[x-mx for x in xs]; dy=[y-my for y in ys]
    vx=sum(x*x for x in dx); vy=sum(y*y for y in dy)
    if vx <= 1e-12 or vy <= 1e-12: return None
    return sum(a*b for a,b in zip(dx,dy))/math.sqrt(vx*vy)


@dataclass(frozen=True)
class _Ref:
    ts: tuple[float,...]
    values: tuple[float,...]


def _ref(series: list[tuple[float,float]]) -> _Ref:
    s=sorted((float(t),float(v)) for t,v in series)
    return _Ref(tuple(x[0] for x in s),tuple(x[1] for x in s))


def _nearest(series: _Ref, t: float, max_delta: float=1.5) -> float | None:
    if not series.ts:return None
    i=bisect_left(series.ts,t); idx=[]
    if i<len(series.ts):idx.append(i)
    if i:idx.append(i-1)
    j=min(idx,key=lambda k:abs(series.ts[k]-t))
    return series.values[j] if abs(series.ts[j]-t)<=max_delta else None


def _field_specs(length: int, changed: set[int]):
    # Small/simple interpretations first. Equivalent value series are later de-duplicated.
    for off in range(length):
        if off in changed:
            yield f'u8@{off}',off,1,'big',False
            yield f's8@{off}',off,1,'big',True
    for width in (2,3,4):
        for off in range(max(0,length-width+1)):
            if not any(i in changed for i in range(off,off+width)):continue
            for endian in ('big','little'):
                yield f'u{width*8}{"be" if endian=="big" else "le"}@{off}',off,width,endian,False
                yield f's{width*8}{"be" if endian=="big" else "le"}@{off}',off,width,endian,True


def rank_did_fields(
    did_rows: Iterable[tuple], *, speed: list[tuple[float,float]], engine_rpm: list[tuple[float,float]],
    hv_power: list[tuple[float,float]], hv_current: list[tuple[float,float]] | None=None, soc: list[tuple[float,float]], top_n: int=100,
) -> list[DidFieldRank]:
    """Prioritize changing fields; semantic names remain hypotheses, never conclusions."""
    grouped: dict[tuple[str,int], list[tuple[float,bytes]]] = {}
    for ts,ecu,did,payload,*_ in did_rows:
        try:t=_parse_ts(str(ts))
        except Exception:continue
        grouped.setdefault((str(ecu).upper(),int(did)),[]).append((t,bytes(payload or b'')))

    refs={k:_ref(v) for k,v in {'speed':speed,'rpm':engine_rpm,'power':hv_power,'current':hv_current or [],'soc':soc}.items()}
    ranked=[]
    for (ecu,did), rows in grouped.items():
        rows.sort(key=lambda x:x[0])
        if len(rows)<5:continue
        min_len=min(len(p) for _,p in rows)
        if min_len<=0:continue
        changed={off for off in range(min_len) if len({p[off] for _,p in rows})>1}
        if not changed:continue
        seen_series=set()
        for name,off,width,endian,signed in _field_specs(min_len,changed):
            vals=[]
            for t,p in rows:
                vals.append((t,float(int.from_bytes(p[off:off+width],endian,signed=signed))))
            raw=[v for _,v in vals]
            if max(raw)==min(raw):continue
            signature=tuple(raw)
            if signature in seen_series:continue
            seen_series.add(signature)
            changing=sum(a!=b for a,b in zip(raw,raw[1:]))/max(1,len(raw)-1)
            pairs={k:([],[]) for k in ('speed','speed_ev','power','current','soc','rpm')}
            for t,v in vals:
                sp=_nearest(refs['speed'],t); rp=_nearest(refs['rpm'],t); pw=_nearest(refs['power'],t); cu=_nearest(refs['current'],t); sv=_nearest(refs['soc'],t)
                if sp is not None:
                    pairs['speed'][0].append(v); pairs['speed'][1].append(sp)
                    if rp is not None and rp < 150 and sp > 0:
                        pairs['speed_ev'][0].append(v); pairs['speed_ev'][1].append(sp)
                if rp is not None:pairs['rpm'][0].append(v); pairs['rpm'][1].append(rp)
                if pw is not None:pairs['power'][0].append(v); pairs['power'][1].append(pw)
                if cu is not None:pairs['current'][0].append(v); pairs['current'][1].append(cu)
                if sv is not None:pairs['soc'][0].append(v); pairs['soc'][1].append(sv)
            cs=_pearson(*pairs['speed']); cev=_pearson(*pairs['speed_ev']); cp=_pearson(*pairs['power']); cc=_pearson(*pairs['current']); cso=_pearson(*pairs['soc']); cr=_pearson(*pairs['rpm'])
            ev=abs(cev or 0.0); allsp=abs(cs or 0.0); soc_pen=abs(cso or 0.0); dynamic=0.45+0.55*min(1.0,changing*3.0)
            motor=max(ev,allsp*0.75)*dynamic*max(0.03,1.0-soc_pen)
            power_score=max(abs(cp or 0.0),abs(cc or 0.0))*dynamic*max(0.10,1.0-0.5*soc_pen)
            priority=max(motor,power_score)+0.02*changing
            note=[]
            if ev>=0.8:note.append('EV区間で車速へ強く追従：モーター回転系候補')
            elif ev>=0.6:note.append('EV区間で車速へ追従')
            if cp is not None and abs(cp)>=0.75:note.append('HV電力と強相関：電流/トルク系候補')
            if cc is not None and abs(cc)>=0.75:note.append('HV電流と強相関：電流系候補')
            if cso is not None and abs(cso)>=0.90:note.append('SOCミラー/バッテリー状態系の可能性')
            if cr is not None and abs(cr)>=0.90:note.append('エンジンRPM系の可能性')
            ranked.append(DidFieldRank(ecu,did,name,len(vals),changing,cev,cs,cp,cc,cso,cr,motor,priority,' / '.join(note) or '意味未確定'))
    ranked.sort(key=lambda r:(r.priority_score,r.motor_score,r.changing_ratio),reverse=True)
    return ranked[:max(1,int(top_n))]


class PositiveDidRoundRobin:
    """Deterministic fair iterator over discovered Positive DIDs."""
    def __init__(self, items, *, exclude_dids=()):
        excluded={int(x) for x in exclude_dids}
        seen=set(); self.items=[]
        for row in items:
            ecu,did,*rest=row; key=(str(ecu).upper(),int(did))
            if key in seen or int(did) in excluded:continue
            seen.add(key); self.items.append((str(ecu).upper(),int(did),*rest))
        self.index=0

    def __len__(self):return len(self.items)

    def next(self):
        if not self.items:return None
        item=self.items[self.index % len(self.items)]
        self.index=(self.index+1)%len(self.items)
        return item
