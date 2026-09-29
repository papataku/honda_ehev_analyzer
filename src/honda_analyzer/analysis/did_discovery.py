from __future__ import annotations

import asyncio
import inspect
import time
from dataclasses import dataclass
from typing import Awaitable, Callable, Iterable

from .did_scan_strategy import (
    known_priority_dids,
    outcome_interest_score,
    page_bounds,
    page_index,
    page_sentinel_dids,
    pages_in_sector,
    prioritized_pages,
    prioritized_sectors,
    sector_head_dids,
    sector_index,
)


TERMINAL_NRC = {0x31}  # Request out of range: treat as checked for resume purposes.
TERMINAL_POSITIVE_STATUSES = {'positive','positive_partial'}


@dataclass(frozen=True)
class DidProbeOutcome:
    ecu: str
    did: int
    status: str  # positive / nrc / no_data / timeout / error / stopped_speed
    latency_ms: float | None = None
    nrc: int | None = None
    payload: bytes = b''
    response_can_id: str | None = None
    raw_text: str = ''


@dataclass(frozen=True)
class DiscoveryProgress:
    ecu: str
    did: int
    completed: int
    total: int
    positive: int
    terminal_negative: int
    retryable: int
    elapsed_s: float
    phase: str = '探索'

    @property
    def percent(self) -> float:
        return 100.0 if self.total <= 0 else 100.0 * self.completed / self.total

    @property
    def achieved_hz(self) -> float:
        return 0.0 if self.elapsed_s <= 0 else self.completed / self.elapsed_s

    @property
    def eta_s(self) -> float | None:
        hz = self.achieved_hz
        if hz <= 0:
            return None
        return max(0.0, self.total - self.completed) / hz


async def _maybe_await(v):
    return await v if inspect.isawaitable(v) else v


class AsyncDidDiscovery:
    """Read-only UDS 0x22 DID discovery engine.

    The engine knows nothing about Qt or ELM headers. Callers supply one async
    read callback and one async speed callback. Safety, resume and adaptive
    priority behaviour therefore remain unit-testable.

    Adaptive full-range order:
      1. known RP8 hot page 0x2000-0x20FF (when in requested range)
      2. coarse 16-sector heads (0x0000, 0x1000, ... plus a short head window)
      3. sparse representatives in every 0x100 page, hot sectors first
      4. pages that produced positive/interesting NRC, fully scanned first
      5. every remaining DID, ordered by observed sector/page density

    This changes *order only*. The final exhaustive pass still covers the whole
    requested range. A silent sentinel never means "skip this region".
    """

    def __init__(
        self,
        probe: Callable[[str, int], Awaitable[DidProbeOutcome]],
        read_speed_kph: Callable[[], Awaitable[float | None]],
        persist: Callable[[DidProbeOutcome], object],
        *,
        stop_requested: Callable[[], bool] | None = None,
        on_progress: Callable[[DiscoveryProgress], object] | None = None,
        sleep: Callable[[float], Awaitable[None]] = asyncio.sleep,
    ):
        self.probe = probe
        self.read_speed_kph = read_speed_kph
        self.persist = persist
        self.stop_requested = stop_requested or (lambda: False)
        self.on_progress = on_progress
        self.sleep = sleep

    async def run(
        self,
        ecus: Iterable[str],
        start: int,
        end: int,
        *,
        rate_hz: float = 2.0,
        completed_by_ecu: dict[str, set[int]] | None = None,
        positive_hints_by_ecu: dict[str, set[int]] | None = None,
        speed_check_interval_s: float = 2.0,
        ecu_chunk_size: int = 256,  # retained for API compatibility
        prioritize_2000: bool = True,
        adaptive_priority: bool = True,
        sector_head_width: int = 4,
        page_sentinel_offsets: tuple[int, ...] = (0x00, 0x80),
    ) -> list[DidProbeOutcome]:
        if not 0 <= start <= end <= 0xFFFF:
            raise ValueError('invalid DID range')
        if rate_hz <= 0:
            raise ValueError('rate_hz must be > 0')
        ecus = tuple(str(e).upper() for e in ecus)
        if not ecus:
            raise ValueError('no ECUs selected')
        completed_by_ecu = {e: set(v) for e, v in (completed_by_ecu or {}).items()}
        positive_hints_by_ecu = {e: set(v) for e, v in (positive_hints_by_ecu or {}).items()}

        total = sum(
            1
            for ecu in ecus
            for did in range(start, end + 1)
            if did not in completed_by_ecu.get(ecu, set())
        )
        if total <= 0:
            return []

        period = 1.0 / rate_hz
        started = time.monotonic()
        next_speed_check = started
        results: list[DidProbeOutcome] = []
        attempted: set[tuple[str, int]] = set()
        positive = terminal_negative = retryable = 0
        consecutive_errors = 0
        abort = False

        # Historical positives seed priorities after an app restart / next day.
        sector_scores: dict[tuple[str, int], int] = {}
        page_scores: dict[tuple[str, int], int] = {}
        for ecu, dids in positive_hints_by_ecu.items():
            for did in dids:
                if start <= did <= end:
                    sector_scores[(ecu, sector_index(did))] = sector_scores.get((ecu, sector_index(did)), 0) + 100
                    page_scores[(ecu, page_index(did))] = page_scores.get((ecu, page_index(did)), 0) + 100

        def is_pending(ecu: str, did: int) -> bool:
            return (
                start <= did <= end
                and did not in completed_by_ecu.get(ecu, set())
                and (ecu, did) not in attempted
            )

        async def probe_one(ecu: str, did: int, phase: str) -> DidProbeOutcome | None:
            nonlocal next_speed_check, positive, terminal_negative, retryable, consecutive_errors, abort
            if abort or self.stop_requested() or not is_pending(ecu, did):
                return None

            now = time.monotonic()
            if now >= next_speed_check:
                speed = await self.read_speed_kph()
                if speed is None or float(speed) > 0.1:
                    outcome = DidProbeOutcome(
                        ecu, did, 'stopped_speed', raw_text=(
                            'vehicle speed unavailable' if speed is None else f'vehicle speed {float(speed):.1f} km/h'
                        )
                    )
                    await _maybe_await(self.persist(outcome))
                    results.append(outcome)
                    if self.on_progress:
                        await _maybe_await(self.on_progress(DiscoveryProgress(
                            ecu, did, len(attempted), total, positive, terminal_negative, retryable,
                            time.monotonic() - started, phase,
                        )))
                    abort = True
                    return outcome
                next_speed_check = time.monotonic() + max(0.5, float(speed_check_interval_s))

            t0 = time.monotonic()
            try:
                outcome = await self.probe(ecu, did)
            except (asyncio.TimeoutError, TimeoutError):
                outcome = DidProbeOutcome(ecu, did, 'timeout', (time.monotonic() - t0) * 1000)
            except Exception as exc:
                outcome = DidProbeOutcome(
                    ecu, did, 'error', (time.monotonic() - t0) * 1000,
                    raw_text=f'{type(exc).__name__}: {exc}',
                )

            attempted.add((ecu, did))
            await _maybe_await(self.persist(outcome))
            results.append(outcome)
            if outcome.status in TERMINAL_POSITIVE_STATUSES:
                positive += 1; consecutive_errors = 0
            elif outcome.status == 'nrc' and outcome.nrc in TERMINAL_NRC:
                terminal_negative += 1; consecutive_errors = 0
            elif outcome.status in ('nrc', 'no_data'):
                retryable += 1; consecutive_errors = 0
            else:
                retryable += 1; consecutive_errors += 1

            score = outcome_interest_score(outcome.status, outcome.nrc)
            if score:
                sector_scores[(ecu, sector_index(did))] = sector_scores.get((ecu, sector_index(did)), 0) + score
                page_scores[(ecu, page_index(did))] = page_scores.get((ecu, page_index(did)), 0) + score

            if self.on_progress:
                await _maybe_await(self.on_progress(DiscoveryProgress(
                    ecu, did, len(attempted), total, positive, terminal_negative, retryable,
                    time.monotonic() - started, phase,
                )))

            if consecutive_errors >= 5:
                abort = True
                return outcome
            remain = period - (time.monotonic() - t0)
            if remain > 0:
                await self.sleep(remain)
            return outcome

        async def run_candidates(candidates, phase: str):
            for ecu, did in candidates:
                if abort or self.stop_requested():
                    return
                await probe_one(ecu, int(did), phase)

        if not adaptive_priority or (end - start + 1) <= 0x100:
            # Keep the original chunk-balanced order for small/manual ranges.
            # Adaptive surveying only pays off on larger searches and changing
            # the short-range order would make manual spot checks harder to read.
            chunk=max(1,int(ecu_chunk_size))
            candidates=[]
            for chunk_start in range(start,end+1,chunk):
                chunk_end=min(end,chunk_start+chunk-1)
                for ecu in ecus:
                    candidates.extend((ecu,did) for did in range(chunk_start,chunk_end+1))
            await run_candidates(candidates, '通常順序')
            return results

        # Phase 1: known useful RP8 page. Full page, but only if it intersects the
        # requested range. This is evidence-based from the already observed 0x2012.
        if prioritize_2000:
            await run_candidates(
                ((ecu, did) for ecu in ecus for did in known_priority_dids(start, end)),
                '1/5 既知2000帯',
            )
        if abort or self.stop_requested():
            return results

        # Phase 2: 16-way coarse survey. Only a short head window per 0x1000
        # sector, so all major regions get a quick chance to promote themselves.
        await run_candidates(
            ((ecu, did) for did in sector_head_dids(start, end, width=sector_head_width) for ecu in ecus),
            '2/5 16領域先頭',
        )
        if abort or self.stop_requested():
            return results

        # Aggregate sector score across ECUs for the next stage. A response from
        # any observed ECU moves that sector earlier, while per-ECU scores still
        # control ordering within it.
        global_sector_scores: dict[int, int] = {}
        for (ecu, sector), score in sector_scores.items():
            global_sector_scores[sector] = global_sector_scores.get(sector, 0) + score

        # Phase 3/4: sparse first/midpoint sampling of each 0x100 page. Hot
        # sectors from phase 2 and historical positive hints are sampled first.
        # As soon as one sector's sparse survey finishes, any hot pages in that
        # sector are fully scanned *before* moving to the next sector. This makes
        # useful clusters surface early instead of waiting for the whole 64K
        # survey to finish.
        deep_scanned_pages: set[tuple[str, int]] = set()
        for sector in prioritized_sectors(start, end, global_sector_scores):
            ecu_order = sorted(ecus, key=lambda e: (-sector_scores.get((e, sector), 0), e))
            candidates = (
                (ecu, did)
                for ecu in ecu_order
                for did in page_sentinel_dids(
                    sector, start, end, offsets=tuple(page_sentinel_offsets)
                )
            )
            await run_candidates(candidates, '3/5 0x100ページ代表')
            if abort or self.stop_requested():
                return results

            hot_pages = sorted(
                (
                    (score, ecu, page)
                    for (ecu, page), score in page_scores.items()
                    if score > 0 and (page >> 4) == sector and (ecu, page) not in deep_scanned_pages
                ),
                key=lambda x: (-x[0], x[1], x[2]),
            )
            for _score, ecu, page in hot_pages:
                p0, p1 = page_bounds(page)
                lo, hi = max(start, p0), min(end, p1)
                if lo <= hi:
                    await run_candidates(((ecu, did) for did in range(lo, hi + 1)), '4/5 反応ページ深掘り')
                    deep_scanned_pages.add((ecu, page))
                if abort or self.stop_requested():
                    return results

        # Recalculate aggregate density after the deep scans, then exhaustively
        # fill every remaining DID. This is the completeness guarantee.
        global_sector_scores.clear()
        global_page_scores: dict[int, int] = {}
        for (ecu, sector), score in sector_scores.items():
            global_sector_scores[sector] = global_sector_scores.get(sector, 0) + score
        for (ecu, page), score in page_scores.items():
            global_page_scores[page] = global_page_scores.get(page, 0) + score

        for sector in prioritized_sectors(start, end, global_sector_scores):
            pages = prioritized_pages(sector, start, end, global_page_scores)
            for page in pages:
                p0, p1 = page_bounds(page)
                lo, hi = max(start, p0), min(end, p1)
                if lo > hi:
                    continue
                # Balance across ECUs one page at a time. Header switching once
                # per 256 DIDs is negligible but prevents one ECU from monopolising
                # hours of a multi-ECU scan.
                ecu_order = sorted(ecus, key=lambda e: (-page_scores.get((e, page), 0), e))
                for ecu in ecu_order:
                    await run_candidates(((ecu, did) for did in range(lo, hi + 1)), '5/5 未探索全埋め')
                    if abort or self.stop_requested():
                        return results
        return results


def estimate_scan_seconds(ecu_count: int, start: int, end: int, rate_hz: float, already_completed: int = 0) -> float:
    if ecu_count < 0 or rate_hz <= 0 or not 0 <= start <= end <= 0xFFFF:
        raise ValueError('invalid scan estimate arguments')
    total = max(0, ecu_count * (end - start + 1) - max(0, int(already_completed)))
    return total / rate_hz


def classify_uds_22_text(text: str, ecu: str, did: int, latency_ms: float | None = None) -> DidProbeOutcome:
    """Classify one ELM response without inventing payload bytes."""
    from honda_analyzer.protocol.elm_text import isotp_messages, isotp_partial_messages
    from honda_analyzer.analysis.ecu_census import expected_response_id_for_ecu

    expected = expected_response_id_for_ecu(ecu)
    for msg in isotp_messages(text):
        if msg.can_id and msg.can_id.upper() != expected:
            continue
        p = msg.payload
        if len(p) >= 3 and p[:3] == b'\x62' + int(did).to_bytes(2, 'big'):
            return DidProbeOutcome(str(ecu).upper(), int(did), 'positive', latency_ms, None, p[3:], msg.can_id or expected, text)
        if len(p) >= 3 and p[0] == 0x7F and p[1] == 0x22:
            return DidProbeOutcome(str(ecu).upper(), int(did), 'nrc', latency_ms, int(p[2]), b'', msg.can_id, text)
    # Long responses from some ELM327-compatible adapters can overflow the
    # adapter's host-output buffer.  If the valid ISO-TP prefix proves that the
    # ECU started a 62 DID positive response, keep the bytes that were actually
    # received and classify it separately rather than losing the DID entirely.
    for frag in isotp_partial_messages(text):
        if frag.can_id and frag.can_id.upper() != expected:
            continue
        p=frag.payload
        if len(p) >= 3 and p[:3] == b'\x62' + int(did).to_bytes(2, 'big'):
            return DidProbeOutcome(str(ecu).upper(), int(did), 'positive_partial', latency_ms, None, p[3:], frag.can_id or expected, text)
    u = str(text).upper()
    if 'NO DATA' in u:
        return DidProbeOutcome(str(ecu).upper(), int(did), 'no_data', latency_ms, raw_text=text)
    return DidProbeOutcome(str(ecu).upper(), int(did), 'error', latency_ms, raw_text=text)
