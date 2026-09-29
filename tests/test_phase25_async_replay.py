from __future__ import annotations

from datetime import datetime, timedelta, timezone

from honda_analyzer.storage.db import SessionDB
from honda_analyzer.storage.async_writer import AsyncSessionWriter
from honda_analyzer.analysis.offline_replay import build_replay_items, ReplayCursor, load_session_replay


def iso(base, seconds):
    return (base + timedelta(seconds=seconds)).isoformat()


def test_async_writer_flush_barrier_makes_all_capture_rows_visible(tmp_path):
    path = tmp_path / 'capture.sqlite3'
    db = SessionDB(path)
    base = datetime(2026,9,24,tzinfo=timezone.utc)
    sid = db.create_session(base.isoformat(), tool_version='test')
    writer = AsyncSessionWriter(path, batch_size=8, flush_interval_s=.01)
    try:
        for i in range(25):
            writer.append_raw(sid, iso(base,i/100), 'BLE', 'notify', bytes([i]))
        writer.append_command(sid, iso(base,1), '010C', b'410C1F40\r>', 12.0, True)
        writer.add_event(sid, iso(base,1.5), 'EV', 'synthetic test marker')
        writer.add_device(sid, 'BLE', 'test-device', {'mtu_size': 23})
        writer.flush()
        assert db.conn.execute('select count(*) from raw_capture where session_id=?',(sid,)).fetchone()[0] == 25
        assert db.conn.execute('select count(*) from commands where session_id=?',(sid,)).fetchone()[0] == 1
        assert db.conn.execute('select count(*) from events where session_id=?',(sid,)).fetchone()[0] == 1
        assert db.conn.execute('select count(*) from devices where session_id=?',(sid,)).fetchone()[0] == 1
        stats=writer.stats()
        assert stats.committed == 28
        assert stats.pending == 0
        assert stats.last_error is None
    finally:
        writer.close()
        db.conn.close()


def test_async_writer_preserves_enqueue_order_within_each_table(tmp_path):
    path=tmp_path/'order.sqlite3'; db=SessionDB(path)
    base=datetime(2026,9,24,tzinfo=timezone.utc); sid=db.create_session(base.isoformat())
    writer=AsyncSessionWriter(path,batch_size=3,flush_interval_s=.01)
    try:
        for cmd in ('010C','010D','0105','019A','222012'):
            writer.append_command(sid,base.isoformat(),cmd,(cmd+'\r>').encode(),1.0,True)
        writer.flush()
        assert [r[1] for r in db.command_rows(sid)] == ['010C','010D','0105','019A','222012']
    finally:
        writer.close();db.conn.close()


def test_offline_replay_decodes_known_signals_keeps_raw_unknown_and_markers():
    base=datetime(2026,9,24,12,0,0,tzinfo=timezone.utc)
    commands=[
        (iso(base,1.0),'010C',b'18DAF11004410C1F40\r>',10.0,1),
        (iso(base,2.0),'010D',b'18DAF11003410D32\r>',11.0,1),
        (iso(base,3.0),'0105',b'18DAF11003410564\r>',12.0,1),
        (iso(base,4.0),'019A',b'18DAF11006419A01020304\r>',13.0,1),
        (iso(base,5.0),'222012',b'18DAF11606622012AABBCC\r>',14.0,1),
    ]
    events=[(iso(base,2.5),'EV','engine off')]
    items=build_replay_items(base.isoformat(),commands,events)
    assert [x.kind for x in items] == ['command','command','event','command','command','command']
    cursor=ReplayCursor(items)
    cursor.consume_until(5.0)
    assert cursor.latest_values['Engine RPM'] == 2000.0
    assert cursor.latest_values['Vehicle Speed'] == 50
    assert cursor.latest_values['Coolant'] == 60
    assert cursor.latest_values['Hybrid/EV 019A'] == '01 02 03 04'
    assert cursor.latest_values['UDS DID 2012'] == 'AA BB CC'
    numeric=cursor.numeric_series_until()
    assert set(numeric) == {'Engine RPM','Vehicle Speed','Coolant'}
    assert [x.event_kind for x in cursor.events_until()] == ['EV']


def test_offline_replay_seek_is_deterministic_and_database_backed(tmp_path):
    path=tmp_path/'replay.sqlite3';db=SessionDB(path)
    base=datetime(2026,9,24,12,0,0,tzinfo=timezone.utc);sid=db.create_session(base.isoformat())
    db.append_command(sid,iso(base,1),'010D',b'410D0A\r>',2,True)
    db.add_event(sid,iso(base,2),'ACCEL','go')
    db.append_command(sid,iso(base,3),'010D',b'410D14\r>',2,True)
    items=load_session_replay(db,sid);cursor=ReplayCursor(items)
    a=cursor.seek(1.5); assert a.latest_values['Vehicle Speed']==10
    b=cursor.seek(3.0); assert b.latest_values['Vehicle Speed']==20
    c=cursor.seek(1.5); assert c.latest_values['Vehicle Speed']==10
    assert cursor.index == 1
    db.conn.close()
