from honda_analyzer.storage.db import SessionDB
from honda_analyzer.diagnostics import live_quality_from_db

def test_live_quality_snapshot(tmp_path):
    db=SessionDB(tmp_path/'x.sqlite3'); sid=db.create_session('2026-01-01T00:00:00Z')
    for i in range(10): db.append_command(sid,'t','010C',b'OK',100+i,True)
    q=live_quality_from_db(db,sid,-60)
    assert q.grade=='GOOD' and q.stats['p95_ms'] is not None
