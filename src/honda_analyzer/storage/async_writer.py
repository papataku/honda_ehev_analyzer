from __future__ import annotations

import json
import queue
import sqlite3
import threading
import time
from dataclasses import dataclass
from pathlib import Path
from typing import Any

from .db import SCHEMA


@dataclass(frozen=True)
class WriterStats:
    enqueued: int
    committed: int
    batches: int
    pending: int
    last_error: str | None


@dataclass(frozen=True)
class _Write:
    sql: str
    params: tuple[Any, ...]


@dataclass(frozen=True)
class _Barrier:
    event: threading.Event


@dataclass(frozen=True)
class _Stop:
    event: threading.Event


class AsyncSessionWriter:
    """Single-writer SQLite worker for capture-path persistence.

    The GUI/capture path only enqueues immutable records. A dedicated thread owns
    its SQLite connection and commits short batches with FULL synchronous mode.
    `flush()` is a durability barrier and is used before session close/export or
    analyses that must see the newest rows.
    """

    def __init__(self, path: str | Path, *, batch_size: int = 64, flush_interval_s: float = 0.10):
        self.path = Path(path)
        self.batch_size = max(1, int(batch_size))
        self.flush_interval_s = max(0.005, float(flush_interval_s))
        self._q: queue.Queue[_Write | _Barrier | _Stop] = queue.Queue()
        self._lock = threading.Lock()
        self._enqueued = 0
        self._committed = 0
        self._batches = 0
        self._last_error: str | None = None
        self._closed = False
        self._thread = threading.Thread(target=self._run, name='honda-sqlite-writer', daemon=True)
        self._thread.start()

    def _check(self) -> None:
        if self._closed:
            raise RuntimeError('AsyncSessionWriter is closed')
        if self._last_error:
            raise RuntimeError(f'AsyncSessionWriter failed: {self._last_error}')

    def _submit(self, sql: str, params: tuple[Any, ...]) -> None:
        self._check()
        self._q.put(_Write(sql, params))
        with self._lock:
            self._enqueued += 1

    def append_raw(self, sid: int, ts: str, layer: str, source: str, payload: bytes) -> None:
        self._submit(
            'INSERT INTO raw_capture(session_id,ts_utc,layer,source,payload) VALUES(?,?,?,?,?)',
            (sid, ts, layer, source, sqlite3.Binary(bytes(payload))),
        )

    def append_command(self, sid: int, ts: str, command: str, raw: bytes, latency_ms: float, success: bool) -> None:
        self._submit(
            'INSERT INTO commands(session_id,ts_utc,command,raw_response,latency_ms,success) VALUES(?,?,?,?,?,?)',
            (sid, ts, command, sqlite3.Binary(bytes(raw)), float(latency_ms), int(bool(success))),
        )

    def add_event(self, sid: int, ts: str, kind: str, note: str | None = None) -> None:
        self._submit(
            'INSERT INTO events(session_id,ts_utc,kind,note) VALUES(?,?,?,?)',
            (sid, ts, kind, note),
        )

    def add_device(self, sid: int, kind: str, identifier: str, metadata: dict[str, Any]) -> None:
        self._submit(
            'INSERT INTO devices(session_id,kind,identifier,metadata_json) VALUES(?,?,?,?)',
            (sid, kind, identifier, json.dumps(metadata, ensure_ascii=False)),
        )

    def add_ui_action(self, sid: int, ts: str, action: str, detail: str | None = None) -> None:
        self._submit(
            'INSERT INTO ui_actions(session_id,ts_utc,action,detail) VALUES(?,?,?,?)',
            (sid, ts, action, detail),
        )


    def save_scan_result(self, sid: int, ecu: str, did: int, status, updated_utc: str, latency_ms=None, nrc=None, payload: bytes=b'', response_can_id=None) -> None:
        status_value = getattr(status, 'value', str(status))
        self._submit(
            'INSERT INTO did_scan(session_id,ecu,did,status,latency_ms,nrc,payload,response_can_id,updated_utc) VALUES(?,?,?,?,?,?,?,?,?) '
            'ON CONFLICT(session_id,ecu,did) DO UPDATE SET status=excluded.status,latency_ms=excluded.latency_ms,nrc=excluded.nrc,payload=excluded.payload,response_can_id=excluded.response_can_id,updated_utc=excluded.updated_utc',
            (sid, str(ecu).upper(), int(did), status_value, latency_ms, nrc, sqlite3.Binary(bytes(payload)), response_can_id, updated_utc),
        )

    def append_did_drive_sample(self, sid: int, ts: str, ecu: str, did: int, response_can_id, payload: bytes, latency_ms=None, success: bool=True, partial: bool=False) -> None:
        self._submit(
            'INSERT INTO did_drive_samples(session_id,ts_utc,ecu,did,response_can_id,payload,latency_ms,success,partial) VALUES(?,?,?,?,?,?,?,?,?)',
            (sid, ts, str(ecu).upper(), int(did), response_can_id, sqlite3.Binary(bytes(payload)), latency_ms, int(bool(success)), int(bool(partial))),
        )

    def save_did_drive_plan_item(self, sid: int, ecu: str, did: int, discovered_session_id, created_utc: str) -> None:
        self._submit(
            'INSERT OR REPLACE INTO did_drive_plan(session_id,ecu,did,discovered_session_id,created_utc) VALUES(?,?,?,?,?)',
            (sid, str(ecu).upper(), int(did), discovered_session_id, created_utc),
        )

    def flush(self, timeout: float = 5.0) -> None:
        self._check()
        e = threading.Event()
        self._q.put(_Barrier(e))
        if not e.wait(timeout):
            raise TimeoutError('Timed out waiting for SQLite writer flush')
        if self._last_error:
            raise RuntimeError(f'AsyncSessionWriter failed: {self._last_error}')

    def close(self, timeout: float = 5.0) -> None:
        if self._closed:
            return
        if not self._last_error:
            self.flush(timeout=timeout)
        e = threading.Event()
        self._q.put(_Stop(e))
        e.wait(timeout)
        self._closed = True
        self._thread.join(timeout=max(0.0, timeout))

    def stats(self) -> WriterStats:
        with self._lock:
            return WriterStats(self._enqueued, self._committed, self._batches, self._q.qsize(), self._last_error)

    def _set_error(self, exc: BaseException) -> None:
        with self._lock:
            self._last_error = f'{type(exc).__name__}: {exc}'

    def _run(self) -> None:
        conn: sqlite3.Connection | None = None
        try:
            self.path.parent.mkdir(parents=True, exist_ok=True)
            conn = sqlite3.connect(self.path, timeout=10.0)
            conn.executescript(SCHEMA)
            conn.execute('PRAGMA journal_mode=WAL')
            conn.execute('PRAGMA synchronous=FULL')
            conn.commit()
            while True:
                try:
                    first = self._q.get(timeout=self.flush_interval_s)
                except queue.Empty:
                    continue

                batch: list[_Write] = []
                terminal: _Barrier | _Stop | None = None

                if isinstance(first, _Write):
                    batch.append(first)
                else:
                    terminal = first

                deadline = time.monotonic() + self.flush_interval_s
                while terminal is None and len(batch) < self.batch_size:
                    remaining = deadline - time.monotonic()
                    if remaining <= 0:
                        break
                    try:
                        item = self._q.get(timeout=remaining)
                    except queue.Empty:
                        break
                    if isinstance(item, _Write):
                        batch.append(item)
                    else:
                        terminal = item
                        break

                if batch:
                    try:
                        conn.execute('BEGIN IMMEDIATE')
                        for item in batch:
                            conn.execute(item.sql, item.params)
                        conn.commit()
                        with self._lock:
                            self._committed += len(batch)
                            self._batches += 1
                    except BaseException as exc:
                        conn.rollback()
                        self._set_error(exc)

                if isinstance(terminal, _Barrier):
                    try:
                        if conn.in_transaction:
                            conn.commit()
                    finally:
                        terminal.event.set()
                elif isinstance(terminal, _Stop):
                    try:
                        if conn.in_transaction:
                            conn.commit()
                    finally:
                        terminal.event.set()
                    return

                if self._last_error:
                    # Fail fast while still releasing any waiting barriers/stops.
                    while True:
                        try:
                            item = self._q.get_nowait()
                        except queue.Empty:
                            return
                        if isinstance(item, (_Barrier, _Stop)):
                            item.event.set()
                            if isinstance(item, _Stop):
                                return
        except BaseException as exc:
            self._set_error(exc)
        finally:
            if conn is not None:
                try:
                    conn.close()
                except Exception:
                    pass
