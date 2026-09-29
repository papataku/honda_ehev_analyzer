from __future__ import annotations

from dataclasses import dataclass
from datetime import datetime, timezone
from typing import Iterable

from honda_analyzer.analysis.live_polling import DEFAULT_POLLS, decode_poll
from honda_analyzer.analysis.live_series import numeric_value


@dataclass(frozen=True)
class ReplayItem:
    elapsed_s: float
    kind: str                  # command | event
    timestamp: str
    command: str | None = None
    text: str | None = None
    latency_ms: float | None = None
    success: bool | None = None
    signal_name: str | None = None
    signal_value: float | str | None = None
    event_kind: str | None = None
    note: str | None = None


@dataclass(frozen=True)
class ReplaySnapshot:
    elapsed_s: float
    index: int
    total: int
    latest_values: dict[str, float | str | None]


def _dt(value: str) -> datetime:
    d = datetime.fromisoformat(value)
    return d if d.tzinfo is not None else d.replace(tzinfo=timezone.utc)


def _text(raw: bytes | None) -> str:
    if not raw:
        return ''
    return bytes(raw).decode('ascii', 'replace')


def build_replay_items(session_started: str, command_rows: Iterable[tuple], event_rows: Iterable[tuple]) -> list[ReplayItem]:
    base = _dt(session_started)
    specs = {s.command.replace(' ', '').upper(): s for s in DEFAULT_POLLS}
    out: list[ReplayItem] = []

    for ts, command, raw, latency_ms, success in command_rows:
        command_key = str(command).replace(' ', '').upper()
        text = _text(raw)
        signal_name = None
        signal_value: float | str | None = None
        spec = specs.get(command_key)
        if spec is not None and bool(success):
            signal_name = spec.name
            signal_value = decode_poll(spec, text)
        out.append(ReplayItem(
            elapsed_s=max(0.0, (_dt(ts) - base).total_seconds()),
            kind='command', timestamp=ts, command=str(command), text=text,
            latency_ms=None if latency_ms is None else float(latency_ms),
            success=bool(success), signal_name=signal_name, signal_value=signal_value,
        ))

    for ts, kind, note in event_rows:
        out.append(ReplayItem(
            elapsed_s=max(0.0, (_dt(ts) - base).total_seconds()),
            kind='event', timestamp=ts, event_kind=str(kind), note=note,
        ))

    out.sort(key=lambda x: (x.elapsed_s, 0 if x.kind == 'command' else 1))
    return out


def load_session_replay(db, sid: int) -> list[ReplayItem]:
    started = db.session_started(sid)
    if not started:
        return []
    return build_replay_items(started, db.command_rows(sid), db.event_rows(sid))


class ReplayCursor:
    """Deterministic, GUI-independent replay cursor supporting play, seek and step."""

    def __init__(self, items: Iterable[ReplayItem]):
        self.items = list(items)
        self.index = 0
        self.latest_values: dict[str, float | str | None] = {}

    @property
    def duration_s(self) -> float:
        return self.items[-1].elapsed_s if self.items else 0.0

    def reset(self) -> None:
        self.index = 0
        self.latest_values = {}

    def seek(self, elapsed_s: float) -> ReplaySnapshot:
        self.reset()
        self.consume_until(max(0.0, float(elapsed_s)))
        return self.snapshot(elapsed_s)

    def step(self) -> ReplayItem | None:
        if self.index >= len(self.items):
            return None
        item = self.items[self.index]
        self.index += 1
        self._apply(item)
        return item

    def consume_until(self, elapsed_s: float) -> list[ReplayItem]:
        consumed: list[ReplayItem] = []
        target = max(0.0, float(elapsed_s))
        while self.index < len(self.items) and self.items[self.index].elapsed_s <= target:
            item = self.step()
            if item is not None:
                consumed.append(item)
        return consumed

    def snapshot(self, elapsed_s: float | None = None) -> ReplaySnapshot:
        if elapsed_s is None:
            if self.index == 0:
                elapsed_s = 0.0
            else:
                elapsed_s = self.items[self.index - 1].elapsed_s
        return ReplaySnapshot(float(elapsed_s), self.index, len(self.items), dict(self.latest_values))

    def numeric_series_until(self, elapsed_s: float | None = None) -> dict[str, tuple[list[float], list[float]]]:
        limit = self.duration_s if elapsed_s is None else float(elapsed_s)
        series: dict[str, tuple[list[float], list[float]]] = {}
        for item in self.items:
            if item.elapsed_s > limit:
                break
            if not item.signal_name:
                continue
            v = numeric_value(item.signal_value)
            if v is None:
                continue
            xs, ys = series.setdefault(item.signal_name, ([], []))
            xs.append(item.elapsed_s); ys.append(v)
        return series

    def events_until(self, elapsed_s: float | None = None) -> list[ReplayItem]:
        limit = self.duration_s if elapsed_s is None else float(elapsed_s)
        return [x for x in self.items if x.kind == 'event' and x.elapsed_s <= limit]

    def _apply(self, item: ReplayItem) -> None:
        if item.signal_name:
            self.latest_values[item.signal_name] = item.signal_value
