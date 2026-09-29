from __future__ import annotations

from collections.abc import Iterable

SECTOR_SIZE = 0x1000
PAGE_SIZE = 0x100
KNOWN_PRIORITY_START = 0x2000
KNOWN_PRIORITY_END = 0x20FF
DEFAULT_SECTOR_HEAD_WIDTH = 4
DEFAULT_PAGE_SENTINEL_OFFSETS = (0x00, 0x80)


def sector_index(did: int) -> int:
    return int(did) >> 12


def page_index(did: int) -> int:
    return int(did) >> 8


def sector_bounds(sector: int) -> tuple[int, int]:
    if not 0 <= int(sector) <= 0xF:
        raise ValueError('sector must be 0..15')
    start = int(sector) * SECTOR_SIZE
    return start, start + SECTOR_SIZE - 1


def page_bounds(page: int) -> tuple[int, int]:
    if not 0 <= int(page) <= 0xFF:
        raise ValueError('page must be 0..255')
    start = int(page) * PAGE_SIZE
    return start, start + PAGE_SIZE - 1


def overlapping_sectors(start: int, end: int) -> list[int]:
    _validate_range(start, end)
    return list(range(start >> 12, (end >> 12) + 1))


def pages_in_sector(sector: int, start: int, end: int) -> list[int]:
    _validate_range(start, end)
    s0, s1 = sector_bounds(sector)
    lo, hi = max(start, s0), min(end, s1)
    if lo > hi:
        return []
    return list(range(lo >> 8, (hi >> 8) + 1))


def known_priority_dids(start: int, end: int) -> Iterable[int]:
    _validate_range(start, end)
    lo, hi = max(start, KNOWN_PRIORITY_START), min(end, KNOWN_PRIORITY_END)
    if lo <= hi:
        yield from range(lo, hi + 1)


def sector_head_dids(start: int, end: int, *, width: int = DEFAULT_SECTOR_HEAD_WIDTH) -> Iterable[int]:
    """Probe the first few DIDs of every 0x1000 sector.

    This gives the 16-way coarse survey requested by the vehicle test workflow.
    It is only a priority hint; a silent head never causes the sector to be
    skipped from the final exhaustive pass.
    """
    _validate_range(start, end)
    width = max(1, int(width))
    for sector in overlapping_sectors(start, end):
        s0, s1 = sector_bounds(sector)
        lo, hi = max(start, s0), min(end, s1)
        for did in range(lo, min(hi, lo + width - 1) + 1):
            yield did


def page_sentinel_dids(
    sector: int,
    start: int,
    end: int,
    *,
    offsets: tuple[int, ...] = DEFAULT_PAGE_SENTINEL_OFFSETS,
) -> Iterable[int]:
    """Yield sparse representatives for each 0x100 page in one sector.

    We use the first and midpoint DID by default.  A positive at either point
    promotes the whole page.  Missing both does *not* mark the page empty; the
    exhaustive pass still covers every DID later.
    """
    _validate_range(start, end)
    for page in pages_in_sector(sector, start, end):
        p0, p1 = page_bounds(page)
        lo, hi = max(start, p0), min(end, p1)
        for off in offsets:
            did = p0 + int(off)
            if lo <= did <= hi:
                yield did


def outcome_interest_score(status: str, nrc: int | None = None) -> int:
    """Score an outcome only for *priority*, never for semantic identification.

    Positive data is strongest.  An NRC other than 0x31 may indicate a DID that
    exists but is unavailable in the current conditions/session, so it receives
    a smaller boost.  NRC 0x31, NO DATA, timeout and transport errors do not make
    a region interesting, but they are still handled by the normal resume rules.
    """
    status = str(status)
    if status in ('positive','positive_partial'):
        return 100
    if status == 'nrc' and nrc is not None and int(nrc) != 0x31:
        return 25
    return 0


def prioritized_sectors(start: int, end: int, scores: dict[int, int] | None = None) -> list[int]:
    scores = scores or {}
    sectors = overlapping_sectors(start, end)
    return sorted(sectors, key=lambda s: (-int(scores.get(s, 0)), s))


def prioritized_pages(sector: int, start: int, end: int, scores: dict[int, int] | None = None) -> list[int]:
    scores = scores or {}
    pages = pages_in_sector(sector, start, end)
    return sorted(pages, key=lambda p: (-int(scores.get(p, 0)), p))


def _validate_range(start: int, end: int) -> None:
    if not 0 <= int(start) <= int(end) <= 0xFFFF:
        raise ValueError('invalid DID range')
