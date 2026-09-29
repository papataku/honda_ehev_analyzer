from dataclasses import dataclass
import re

CAN_ID_RE = re.compile(r'(?i)\b([0-9a-f]{8})\b')

@dataclass(frozen=True)
class EcuResponse:
    request_id: str
    response_id: str | None
    ecu: str | None
    positive: bool
    did: int | None
    nrc: int | None
    payload_hex: str


def response_ecu_from_29bit(can_id: str) -> str | None:
    """Return source ECU byte from common 18DAF1xx physical-response ID.
    Do not assume every Honda response follows this pattern.
    """
    s = can_id.upper().replace('0X','')
    if len(s) == 8 and s.startswith('18DAF1'):
        return s[-2:]
    return None


def parse_elm_header_line(line: str, request_id: str = '18DBEFF1') -> EcuResponse | None:
    """Parse an already ISO-TP-reassembled ELM text line containing header + UDS payload.
    This intentionally refuses to guess fragmented ISO-TP layout.
    """
    compact = ''.join(line.strip().split()).upper()
    if len(compact) < 8: return None
    can_id = compact[:8]
    try: int(can_id,16)
    except ValueError: return None
    data = compact[8:]
    # tolerate an ELM-reported byte count before payload
    for candidate in (data, data[2:] if len(data)>=2 else ''):
        if candidate.startswith('62') and len(candidate) >= 6:
            did=int(candidate[2:6],16)
            return EcuResponse(request_id,can_id,response_ecu_from_29bit(can_id),True,did,None,candidate)
        if candidate.startswith('7F22') and len(candidate)>=6:
            return EcuResponse(request_id,can_id,response_ecu_from_29bit(can_id),False,None,int(candidate[4:6],16),candidate)
    return None
