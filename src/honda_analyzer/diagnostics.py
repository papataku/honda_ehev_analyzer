from __future__ import annotations
import json, sqlite3
from pathlib import Path
from .analysis.communication_quality import assess_communication_quality


def _failure_counts(rows):
    timeouts=errors=0
    for latency,ok,raw in rows:
        if ok: continue
        text=bytes(raw or b'').decode('ascii','ignore').upper()
        if 'TIMEOUT' in text:
            timeouts += 1
        elif 'NO DATA' in text:
            # Valid ELM outcome / unsupported query, not a BLE/CAN link failure.
            continue
        else:
            errors += 1
    return timeouts,errors


def session_diagnostics(db_path, session_id, *, rssi_dbm=None):
    conn=sqlite3.connect(db_path)
    rows=conn.execute('SELECT latency_ms,success,raw_response FROM commands WHERE session_id=? ORDER BY id',(session_id,)).fetchall()
    raw=conn.execute('SELECT payload FROM raw_capture WHERE session_id=?',(session_id,)).fetchall()
    conn.close()
    lat=[r[0] for r in rows if r[1] and r[0] is not None]; timeouts,errors=_failure_counts(rows)
    return assess_communication_quality(lat,rssi_dbm=rssi_dbm,timeouts=timeouts,errors=errors,total_requests=len(rows),notifications=len(raw),byte_count=sum(len(x[0]) for x in raw))


def write_diagnostics_json(path, quality):
    Path(path).write_text(json.dumps(quality.to_dict(),ensure_ascii=False,indent=2),encoding='utf-8'); return Path(path)


def live_quality_from_db(db, session_id, rssi_dbm=None):
    """Compute a rolling/session communication quality snapshot without mutating raw data."""
    rows=db.conn.execute("SELECT latency_ms,success,raw_response FROM commands WHERE session_id=? ORDER BY id DESC LIMIT 200",(session_id,)).fetchall()
    lat=[r[0] for r in rows if r[1] and r[0] is not None]; timeouts,errors=_failure_counts(rows)
    raw=db.conn.execute("SELECT payload FROM raw_capture WHERE session_id=? ORDER BY id DESC LIMIT 1000",(session_id,)).fetchall()
    return assess_communication_quality(lat,rssi_dbm=rssi_dbm,timeouts=timeouts,errors=errors,total_requests=len(rows),notifications=len(raw),byte_count=sum(len(x[0]) for x in raw))
