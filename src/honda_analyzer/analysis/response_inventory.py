from __future__ import annotations
from dataclasses import dataclass
from collections import defaultdict
from honda_analyzer.protocol.elm_text import isotp_messages

@dataclass(frozen=True)
class ResponseInventoryEntry:
    response_can_id: str
    command: str
    samples: int
    unique_payloads: int
    payload_length_min: int
    payload_length_max: int
    changing_byte_count: int


def _changing_byte_count(payloads: list[bytes]) -> int:
    if not payloads:
        return 0
    width=max(len(p) for p in payloads)
    changed=0
    for i in range(width):
        values={p[i] for p in payloads if i < len(p)}
        missing=any(i >= len(p) for p in payloads)
        if len(values)>1 or (missing and values):
            changed+=1
    return changed


def diagnostic_response_inventory(command_rows) -> tuple[ResponseInventoryEntry,...]:
    """Summarize every CAN-ID-bearing diagnostic response preserved by ELM logs.

    This analyzes responses to commands the analyzer actually sent. It is not a
    passive inventory of every CAN frame on the vehicle network.
    """
    groups=defaultdict(list)
    for row in command_rows:
        if len(row)<5:
            continue
        _ts,command,raw,_latency,success=row[:5]
        if not success or not raw:
            continue
        text=bytes(raw).decode('ascii','replace') if isinstance(raw,(bytes,bytearray,memoryview)) else str(raw)
        for msg in isotp_messages(text):
            if not msg.can_id:
                continue
            groups[(msg.can_id.upper(),''.join(str(command).upper().split()))].append(bytes(msg.payload))
    out=[]
    for (can_id,command),payloads in sorted(groups.items()):
        lengths=[len(p) for p in payloads]
        out.append(ResponseInventoryEntry(
            can_id,command,len(payloads),len(set(payloads)),min(lengths),max(lengths),_changing_byte_count(payloads)
        ))
    return tuple(out)
