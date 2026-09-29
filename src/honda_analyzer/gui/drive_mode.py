from __future__ import annotations
from dataclasses import dataclass

MARKERS = ("STOP", "EV", "ENGINE ON", "ACCEL", "CRUISE", "REGEN", "CUSTOM")
SHORTCUTS = {"1":"STOP","2":"EV","3":"ENGINE ON","4":"ACCEL","5":"CRUISE","6":"REGEN"}

@dataclass(frozen=True)
class DriveAlert:
    severity: str
    message: str


def communication_alert(grade: str, timeout_rate: float, error_rate: float, p95_ms: float | None) -> DriveAlert:
    """Small deterministic policy for the passenger-facing drive screen.

    It intentionally reports communication health only; it never infers vehicle safety.
    """
    grade=(grade or "NO DATA").upper()
    if grade == "NO DATA":
        return DriveAlert("INFO", "Waiting for communication samples")
    if timeout_rate >= .10 or error_rate >= .10 or grade == "POOR":
        return DriveAlert("ALERT", "Communication degraded — preserve the session and avoid starting scans")
    if timeout_rate >= .03 or error_rate >= .03 or grade == "FAIR" or (p95_ms is not None and p95_ms >= 1000):
        return DriveAlert("WARN", "Communication quality is reduced; continue logging")
    return DriveAlert("OK", "Logging normally")
