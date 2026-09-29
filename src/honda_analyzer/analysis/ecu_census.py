from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

from honda_analyzer.analysis.discovery import response_ecu_from_29bit
from honda_analyzer.protocol.elm_text import parse_hex_rows

# Conservative, read-only requests used by the guided ECU census.
# They are intentionally a tiny allow-list. This is not a PID/DID brute-force scan.
SAFE_CENSUS_REQUESTS = (
    ("OBD対応PID確認", "0100", "18DB33F1"),
    ("エンジン回転数", "010C", "18DB33F1"),
    ("車速", "010D", "18DB33F1"),
    ("冷却水温", "0105", "18DB33F1"),
    ("標準 Hybrid/EV PID 9A", "019A", "18DB33F1"),
    ("Honda DID 2012", "222012", "18DBEFF1"),
)

SAFE_CENSUS_COMMANDS = {x[1] for x in SAFE_CENSUS_REQUESTS}


def normalize_command(command: str) -> str:
    return "".join(str(command).upper().split())


@dataclass(frozen=True)
class EcuCensusEntry:
    ecu: str
    response_can_id: str
    response_count: int
    commands: tuple[str, ...]
    first_seen_utc: str | None = None
    last_seen_utc: str | None = None


@dataclass(frozen=True)
class EcuCensus:
    entries: tuple[EcuCensusEntry, ...]
    matrix: dict[tuple[str, str], int]
    sample_count: int

    @property
    def responder_count(self) -> int:
        return len(self.entries)


def _raw_text(raw: bytes | bytearray | memoryview | None) -> str:
    if not raw:
        return ""
    return bytes(raw).decode("ascii", "replace")


def passive_ecu_census(command_rows: Iterable[tuple], *, safe_only: bool = False) -> EcuCensus:
    """Build a responder census from already-saved ELM command responses.

    This never transmits anything to the vehicle.  Only 29-bit response IDs in the
    common diagnostic form ``18DAF1xx`` are counted as ECU responders.  The result
    therefore means "responders observed in this session", not total ECUs installed.
    """
    stats: dict[tuple[str, str], dict] = {}
    matrix: dict[tuple[str, str], int] = {}
    samples = 0

    for row in command_rows:
        if len(row) < 5:
            continue
        ts, command, raw, _latency_ms, success = row[:5]
        cmd = normalize_command(command)
        if safe_only and cmd not in SAFE_CENSUS_COMMANDS:
            continue
        if not bool(success):
            continue
        text = _raw_text(raw)
        seen_this_response: set[str] = set()
        for parsed in parse_hex_rows(text):
            can_id = (parsed.can_id or "").upper()
            ecu = response_ecu_from_29bit(can_id)
            if ecu is None:
                continue
            samples += 1
            key = (ecu, can_id)
            st = stats.setdefault(key, {
                "count": 0,
                "commands": set(),
                "first": ts,
                "last": ts,
            })
            # Count one response ID once per ELM command response even if an ISO-TP
            # message spans multiple CAN frames.
            if can_id not in seen_this_response:
                st["count"] += 1
                matrix[(ecu, cmd)] = matrix.get((ecu, cmd), 0) + 1
                seen_this_response.add(can_id)
            st["commands"].add(cmd)
            st["last"] = ts

    entries = []
    for (ecu, can_id), st in sorted(stats.items(), key=lambda x: (int(x[0][0], 16), x[0][1])):
        entries.append(EcuCensusEntry(
            ecu=ecu,
            response_can_id=can_id,
            response_count=int(st["count"]),
            commands=tuple(sorted(st["commands"])),
            first_seen_utc=st["first"],
            last_seen_utc=st["last"],
        ))
    return EcuCensus(tuple(entries), matrix, samples)


def physical_request_id_for_ecu(ecu: str) -> str:
    """Map a responder source byte xx to standard 29-bit physical request 18DAxxF1."""
    e = str(ecu).upper().replace("0X", "")
    if len(e) != 2:
        raise ValueError("ECU source must be exactly one byte (00-FF)")
    try:
        int(e, 16)
    except ValueError as exc:
        raise ValueError("ECU source must be hexadecimal (00-FF)") from exc
    return f"18DA{e}F1"


def expected_response_id_for_ecu(ecu: str) -> str:
    e = str(ecu).upper().replace("0X", "")
    if len(e) != 2:
        raise ValueError("ECU source must be exactly one byte (00-FF)")
    int(e, 16)
    return f"18DAF1{e}"
