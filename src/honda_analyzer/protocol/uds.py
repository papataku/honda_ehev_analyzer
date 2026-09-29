from dataclasses import dataclass

@dataclass(frozen=True)
class UdsResult:
    positive: bool
    service: int
    did: int | None
    payload: bytes
    nrc: int | None = None

def parse_22_response(payload: bytes) -> UdsResult:
    if len(payload) >= 3 and payload[0] == 0x62:
        return UdsResult(True, 0x22, int.from_bytes(payload[1:3], 'big'), payload[3:])
    if len(payload) >= 3 and payload[0] == 0x7F and payload[1] == 0x22:
        return UdsResult(False, 0x22, None, b'', payload[2])
    raise ValueError("not a UDS ReadDataByIdentifier response")

def safe_scan_request(did: int) -> bytes:
    if not 0 <= did <= 0xFFFF: raise ValueError("DID out of range")
    return bytes([0x22, did >> 8, did & 0xFF])
