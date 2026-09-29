from __future__ import annotations
from dataclasses import dataclass
import re

_HEX = re.compile(r'^[0-9A-Fa-f]+$')
_SEGMENT = re.compile(r'^([0-9A-Fa-f]+)\s*:\s*([0-9A-Fa-f ]+)$')

@dataclass(frozen=True)
class ElmHexRow:
    can_id: str | None
    data: bytes

@dataclass(frozen=True)
class IsoTpMessage:
    can_id: str | None
    payload: bytes

@dataclass(frozen=True)
class IsoTpPartial:
    """An incomplete ISO-TP/application payload captured before ELM truncation.

    ``payload`` contains only bytes that were actually received. ``total_length``
    is taken from the ISO-TP First Frame or CAF1 length line; no missing bytes are
    invented. This is useful for identifying a DID as real even when a clone
    reports ``BUFFER FULL`` before the complete response reaches the host.
    """
    can_id: str | None
    payload: bytes
    total_length: int | None


def _compact_hex(line: str) -> str | None:
    s=''.join(line.strip().split())
    if not s or len(s)%2 or not _HEX.fullmatch(s):
        return None
    return s.upper()


def parse_hex_rows(text: str) -> list[ElmHexRow]:
    """Parse ELM hex lines with or without ATS0 spaces.

    Honda RP8 capture uses 29-bit 18DA/18DB IDs. We only split a compact
    leading 8-hex CAN ID when it matches those diagnostic families; otherwise
    the entire line remains data. Raw text remains the authority.
    """
    out=[]
    for line in text.replace('>','\n').splitlines():
        compact=_compact_hex(line)
        if not compact:
            continue
        can_id=None
        body=compact
        if len(compact) >= 10 and compact[:8].startswith(('18DA','18DB')):
            can_id=compact[:8]
            body=compact[8:]
        if body and len(body)%2==0:
            out.append(ElmHexRow(can_id,bytes.fromhex(body)))
    return out


def hex_lines(text: str) -> list[bytes]:
    """Compatibility helper returning data bytes (CAN header removed when recognized)."""
    return [r.data for r in parse_hex_rows(text)]


def _caf1_headerless_blocks(text: str) -> list[tuple[bytes, int, bool]]:
    """Parse ELM CAF1/H0 multiline output.

    With CAN auto formatting enabled and headers disabled, official ELM327
    firmware prints a three-hex-digit total byte count followed by numbered
    ``0: ...``, ``1: ...`` data lines.  Clones generally follow the same form.
    Return (received_payload, declared_length, complete) tuples.  Segment labels
    are deliberately not trusted for semantics; bytes are appended in the order
    printed by the ELM.
    """
    raw_lines=[ln.strip() for ln in text.replace('>','\n').splitlines() if ln.strip()]
    out=[]; i=0
    while i < len(raw_lines):
        length_token=''.join(raw_lines[i].split())
        if not (len(length_token)==3 and _HEX.fullmatch(length_token)):
            i+=1; continue
        # A length line is only accepted when immediately followed by a segment.
        if i+1 >= len(raw_lines) or not _SEGMENT.match(raw_lines[i+1]):
            i+=1; continue
        total=int(length_token,16); data=bytearray(); j=i+1
        while j < len(raw_lines):
            m=_SEGMENT.match(raw_lines[j])
            if not m: break
            body=''.join(m.group(2).split())
            if len(body)%2 or not _HEX.fullmatch(body): break
            data.extend(bytes.fromhex(body)); j+=1
            if len(data) >= total: break
        out.append((bytes(data[:total]),total,len(data)>=total))
        i=max(j,i+1)
    return out


def isotp_messages(text: str) -> list[IsoTpMessage]:
    """Best-effort ISO-TP reassembly for ELM text.

    Supports compact/spaced 29-bit lines, SF/FF/CF framing, headerless CAF1
    multiline formatting, and already ELM-reassembled payload lines. Malformed
    sequences are retained only as independent data; no bytes are invented.
    """
    out=[]
    for payload,total,complete in _caf1_headerless_blocks(text):
        if complete:
            out.append(IsoTpMessage(None,payload[:total]))

    rows=parse_hex_rows(text)
    active: dict[str|None, tuple[int, bytearray, int]] = {}
    for row in rows:
        d=row.data
        if not d:
            continue
        pci=d[0] >> 4
        key=row.can_id
        if pci == 0x0 and 0 < (d[0] & 0x0F) <= 7:
            n=d[0] & 0x0F
            if n <= len(d)-1:
                out.append(IsoTpMessage(key,d[1:1+n]))
                continue
        if pci == 0x1 and len(d) >= 2:
            total=((d[0] & 0x0F) << 8) | d[1]
            buf=bytearray(d[2:])
            active[key]=(total,buf,1)
            if len(buf) >= total:
                out.append(IsoTpMessage(key,bytes(buf[:total])))
                del active[key]
            continue
        if pci == 0x2 and key in active:
            total,buf,next_seq=active[key]
            seq=d[0] & 0x0F
            if seq == (next_seq & 0x0F):
                buf.extend(d[1:])
                next_seq=(next_seq+1)&0x0F
                if len(buf) >= total:
                    out.append(IsoTpMessage(key,bytes(buf[:total])))
                    del active[key]
                else:
                    active[key]=(total,buf,next_seq)
            else:
                del active[key]
            continue
        if pci == 0x3:
            # Flow-control frame is transport metadata, not application payload.
            continue
        # Already formatted/reassembled application payload (common with CAF1).
        out.append(IsoTpMessage(key,d))
    return out


def isotp_partial_messages(text: str) -> list[IsoTpPartial]:
    """Return incomplete payload prefixes without pretending they are complete."""
    out=[]
    for payload,total,complete in _caf1_headerless_blocks(text):
        if not complete and payload:
            out.append(IsoTpPartial(None,payload,total))

    active: dict[str|None, tuple[int, bytearray, int]] = {}
    for row in parse_hex_rows(text):
        d=row.data
        if not d: continue
        pci=d[0] >> 4; key=row.can_id
        if pci==0x1 and len(d)>=2:
            total=((d[0]&0x0F)<<8)|d[1]
            active[key]=(total,bytearray(d[2:]),1)
            continue
        if pci==0x2 and key in active:
            total,buf,next_seq=active[key]; seq=d[0]&0x0F
            if seq==(next_seq&0x0F):
                buf.extend(d[1:]); next_seq=(next_seq+1)&0x0F
                if len(buf)>=total:
                    del active[key]
                else:
                    active[key]=(total,buf,next_seq)
            else:
                # Preserve the valid prefix accumulated before sequence loss.
                if buf: out.append(IsoTpPartial(key,bytes(buf),total))
                del active[key]
    for key,(total,buf,_seq) in active.items():
        if buf and len(buf)<total:
            out.append(IsoTpPartial(key,bytes(buf),total))
    return out


def find_service_payload(text: str, prefix: bytes) -> tuple[bytes,str|None] | None:
    """Return bytes after a positive-service prefix and its response CAN ID.

    Some ELM clones print one already-formatted long response over multiple lines
    and repeat the service/PID prefix on each line. When those lines share the
    same CAN ID, concatenate only their data portions. Responses from different
    ECUs are never merged.
    """
    hits=[]
    for msg in isotp_messages(text):
        i=msg.payload.find(prefix)
        if i >= 0:
            hits.append((msg.payload[i+len(prefix):],msg.can_id))
    if not hits:
        return None
    first_id=hits[0][1]
    return b''.join(p for p,cid in hits if cid==first_id),first_id


def find_obd_payload(text: str, mode: int, pid: int) -> bytes | None:
    hit=find_service_payload(text,bytes((mode+0x40,pid)))
    return hit[0] if hit else None


def find_uds_22_payload(text: str, did: int) -> tuple[bytes,str|None] | None:
    return find_service_payload(text,b'\x62'+int(did).to_bytes(2,'big'))
