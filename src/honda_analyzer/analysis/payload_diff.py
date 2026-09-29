from __future__ import annotations
from dataclasses import dataclass
from datetime import datetime
from collections import Counter
from honda_analyzer.protocol.elm_text import isotp_messages, find_obd_payload, find_uds_22_payload

@dataclass(frozen=True)
class ByteDiff:
    offset:int; a:int|None; b:int|None; changed:bool

@dataclass(frozen=True)
class PayloadSnapshot:
    command:str; start_s:float; end_s:float; payload:bytes; samples:int


def elm_hex_bytes(raw: bytes|str) -> bytes:
    """Best-effort application bytes for generic visualization.

    Unlike the original token-regex implementation, this handles ATS0 compact
    responses and ISO-TP framing. For command-aware analysis use
    ``elm_command_payload`` so service/PID/DID bytes are excluded.
    """
    text=raw.decode('ascii','ignore') if isinstance(raw,(bytes,bytearray)) else str(raw)
    msgs=isotp_messages(text)
    return msgs[0].payload if msgs else b''


def elm_command_payload(raw: bytes|str, command: str) -> bytes:
    """Extract only the data bytes for a supported read command."""
    text=raw.decode('ascii','ignore') if isinstance(raw,(bytes,bytearray)) else str(raw)
    cmd=''.join(str(command).split()).upper()
    if cmd=='019A':
        return find_obd_payload(text,1,0x9A) or b''
    if cmd=='222012':
        hit=find_uds_22_payload(text,0x2012)
        return hit[0] if hit else b''
    if cmd=='010C':
        return find_obd_payload(text,1,0x0C) or b''
    if cmd=='010D':
        return find_obd_payload(text,1,0x0D) or b''
    if cmd=='0105':
        return find_obd_payload(text,1,0x05) or b''
    return elm_hex_bytes(text)


def representative_payload(rows:list[tuple[str,bytes]], command:str, start:datetime, end:datetime) -> PayloadSnapshot:
    vals=[]
    for ts,raw in rows:
        dt=datetime.fromisoformat(ts)
        if start <= dt <= end:
            p=elm_command_payload(raw,command)
            if p: vals.append(p)
    if not vals:return PayloadSnapshot(command,0,0,b'',0)
    payload=Counter(vals).most_common(1)[0][0]
    return PayloadSnapshot(command,0,0,payload,len(vals))


def diff_payloads(a:bytes,b:bytes)->list[ByteDiff]:
    n=max(len(a),len(b));out=[]
    for i in range(n):
        av=a[i] if i<len(a) else None; bv=b[i] if i<len(b) else None
        out.append(ByteDiff(i,av,bv,av!=bv))
    return out


def activity_matrix(payloads:list[bytes])->list[float]:
    """Per-byte change ratio [0,1], suitable for heatmap/activity ranking."""
    if len(payloads)<2:return [0.0]*(max((len(x) for x in payloads),default=0))
    n=max(len(x) for x in payloads); ratios=[]
    for i in range(n):
        changes=valid=0;prev=None
        for p in payloads:
            cur=p[i] if i<len(p) else None
            if prev is not None and cur is not None:
                valid+=1;changes+=cur!=prev
            prev=cur
        ratios.append(changes/valid if valid else 0.0)
    return ratios
