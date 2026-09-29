from __future__ import annotations

from dataclasses import dataclass


@dataclass(frozen=True)
class DidScanTimingProfile:
    """ELM timing profile used only while stationary DID discovery is active.

    ELM327 ATST is expressed in 4 ms units.  The fast profile keeps enough
    margin for ordinary UDS P2 responses while shortening the post-response
    wait that dominated the Session 14 scan.  Retryable NO DATA / timeout
    results are deliberately *not* marked complete, so a slow responder is not
    permanently discarded by the fast pass.
    """

    target_hz: float
    setup_commands: tuple[str, ...]
    restore_commands: tuple[str, ...]
    name: str
    note: str


def profile_for_rate(rate_hz: float) -> DidScanTimingProfile:
    rate = float(rate_hz)
    if rate <= 0:
        raise ValueError('rate_hz must be > 0')
    if rate >= 8.0:
        return DidScanTimingProfile(
            rate,
            ('ATAT2', 'ATST0F'),  # aggressive adaptive timing, 60 ms maximum timeout
            ('ATAT1', 'ATST32'),  # ELM defaults/recommended adaptive mode, ~200 ms max
            '高速',
            '10 req/sを狙う高速設定。NO DATA/timeoutは確認済みにせず次回再試行します。',
        )
    if rate >= 5.0:
        return DidScanTimingProfile(
            rate,
            ('ATAT2', 'ATST19'),  # 100 ms maximum timeout
            ('ATAT1', 'ATST32'),
            '中速',
            '応答待ち上限を約100 msへ短縮します。',
        )
    return DidScanTimingProfile(
        rate,
        (),
        (),
        '標準',
        'ELMの通常タイミング設定を変更しません。',
    )


def prioritized_scan_ranges(start: int, end: int, *, prioritize_2000: bool = True) -> list[tuple[int, int]]:
    """Return non-overlapping ranges covering [start, end].

    The RP8 already proved that DID 0x2012 exists.  For a full-range scan we
    therefore examine 0x2000-0x20FF first so useful positives appear within
    minutes, then fill the rest of the requested range.  Coverage remains
    complete; only the order changes.
    """
    if not 0 <= start <= end <= 0xFFFF:
        raise ValueError('invalid DID range')
    if not prioritize_2000:
        return [(start, end)]
    p0, p1 = max(start, 0x2000), min(end, 0x20FF)
    if p0 > p1:
        return [(start, end)]
    out = [(p0, p1)]
    if start < p0:
        out.append((start, p0 - 1))
    if p1 < end:
        out.append((p1 + 1, end))
    return out
