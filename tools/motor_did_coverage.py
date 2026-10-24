#!/usr/bin/env python3
"""Read-only Honda e:HEV DID capture coverage gate, NOT a motor signal decoder.

No transmit commands, no interpretation of manufacturer fields, no raw trip export.
Only aggregate metadata is emitted. Intended for completed iPad SQLite sessions.
"""
from __future__ import annotations

import argparse
import bisect
import json
import re
import sqlite3
import statistics
from collections import defaultdict
from datetime import datetime
from pathlib import Path
from urllib.parse import quote

REQUIRED = {"commands", "did_drive_samples"}
KNOWN_ECUS = ("01", "0E", "EF")
SPEED_MAX_AGE_S = 1.5
ENGINE_MAX_AGE_S = 1.5


def epoch(value: str) -> float:
    return datetime.fromisoformat(value.replace("Z", "+00:00")).timestamp()


def decode_mode01(command: str, response: bytes) -> float | None:
    """Use ECU01 ISO-TP single-frame Mode01 references only, never a random ECU."""
    if command not in {"010C", "010D"}:
        return None
    try:
        body = response.decode("ascii")
    except UnicodeDecodeError:
        return None
    mode = "0C" if command == "010C" else "0D"
    payload_len = 4 if mode == "0C" else 3
    pattern = rf"^18DAF1010{payload_len}41{mode}([0-9A-F]{{{4 if mode == '0C' else 2}}})$"
    for line in body.upper().replace("\n", "\r").split("\r"):
        match = re.fullmatch(pattern, line.strip())
        if match:
            val = int(match.group(1), 16)
            return val / 4.0 if mode == "0C" else float(val)
    return None


def last_before(observations: list[tuple[float, float]], when: float, max_age: float) -> float | None:
    if not observations:
        return None
    idx = bisect.bisect_right(observations, (when, float("inf"))) - 1
    if idx < 0 or when - observations[idx][0] > max_age:
        return None
    return observations[idx][1]


def percentile95(values: list[float]) -> float | None:
    return sorted(values)[min(len(values) - 1, int((len(values) - 1) * .95))] if values else None


def summarize(path: str | Path) -> dict:
    p = Path(path).expanduser().resolve()
    uri = f"file:{quote(str(p), safe='/')}?mode=ro"
    conn = sqlite3.connect(uri, uri=True)
    try:
        tables = {row[0] for row in conn.execute("SELECT name FROM sqlite_master WHERE type='table'")}
        if not REQUIRED.issubset(tables):
            raise ValueError(f"required tables missing: {sorted(REQUIRED - tables)}")
        references: dict[str, list[tuple[float, float]]] = {"010C": [], "010D": []}
        for ts, command, raw in conn.execute(
            "SELECT ts_utc, command, raw_response FROM commands "
            "WHERE command IN ('010C','010D') AND raw_response IS NOT NULL ORDER BY ts_utc"
        ):
            val = decode_mode01(command, raw)
            if val is not None:
                references[command].append((epoch(ts), val))
        for k in references:
            references[k].sort()
        groups: dict[tuple[str, int], list[tuple[float, bytes, str | None]]] = defaultdict(list)
        invalid = 0
        for ts, ecu, did, payload, responder, success, partial in conn.execute(
            "SELECT ts_utc, ecu, did, payload, response_can_id, success, partial "
            "FROM did_drive_samples ORDER BY ts_utc"
        ):
            if not success or partial or payload is None or len(payload) == 0:
                invalid += 1
                continue
            groups[(ecu.upper(), int(did))].append((epoch(ts), payload, responder))
        result = []
        for (ecu, did), samples in sorted(groups.items()):
            times = [s[0] for s in samples]
            intervals = [b-a for a, b in zip(times, times[1:]) if b >= a]
            seen = {bytes(p) for _, p, _ in samples}
            sizes = sorted({len(p) for _, p, _ in samples})
            changed = [i for i in range(min(sizes)) if len({p[i] for _, p, _ in samples}) > 1]
            context = {"ev_moving": 0, "engine_moving": 0, "stationary": 0, "unpaired": 0}
            unique_speeds = set()
            mismatched = 0
            for when, _, responder in samples:
                if responder and responder.upper() != f"18DAF1{ecu}":
                    mismatched += 1
                speed = last_before(references["010D"], when, SPEED_MAX_AGE_S)
                rpm = last_before(references["010C"], when, ENGINE_MAX_AGE_S)
                if speed is None or rpm is None:
                    context["unpaired"] += 1
                elif speed <= 0.5:
                    context["stationary"] += 1
                elif speed > 5 and rpm <= 50:
                    context["ev_moving"] += 1
                    unique_speeds.add(speed)
                elif speed > 5 and rpm >= 300:
                    context["engine_moving"] += 1
                else:
                    context["unpaired"] += 1
            sufficient = (
                len(samples) >= 50 and len(seen) >= 5 and len(changed) > 0
                and context["ev_moving"] >= 10 and context["engine_moving"] >= 10
                and len(unique_speeds) >= 5 and mismatched == 0
            )
            result.append({
                "ecu": ecu, "did": f"{did:04X}", "samples": len(samples),
                "unique_payloads": len(seen), "payload_lengths": sizes,
                "changing_byte_offsets": changed, "span_s": round(times[-1]-times[0], 3),
                "median_gap_s": round(statistics.median(intervals), 3) if intervals else None,
                "p95_gap_s": round(percentile95(intervals), 3) if intervals else None,
                "contexts": context, "ev_speed_levels": len(unique_speeds),
                "unexpected_responder_count": mismatched,
                "screening_ready": sufficient,
                "semantics": "UNKNOWN", "why": "sample coverage only; not a motor RPM/torque definition",
            })
        present = sorted({x["ecu"] for x in result})
        return {
            "input_name": p.name,
            "kind": "READ_ONLY_CAPTURE_COVERAGE_NO_CAN_TX",
            "reference_counts": {k: len(v) for k, v in references.items()},
            "complete_did_samples": sum(x["samples"] for x in result),
            "invalid_or_partial_did_samples": invalid,
            "ecu_sources_present": present,
            "priority_ecus_without_samples": [e for e in KNOWN_ECUS if e not in present],
            "did_coverage": result,
            "conclusion": "No field is promoted to motor/generator RPM or torque by this tool.",
        }
    finally:
        conn.close()


def main() -> None:
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("session", help="Closed iPad .sqlite3 file, opened read-only")
    ap.add_argument("--output", help="Local aggregate-only JSON output path")
    args = ap.parse_args()
    report = summarize(args.session)
    body = json.dumps(report, ensure_ascii=False, indent=2) + "\n"
    if args.output:
        Path(args.output).write_text(body, encoding="utf-8")
    else:
        print(body, end="")


if __name__ == "__main__":
    main()
