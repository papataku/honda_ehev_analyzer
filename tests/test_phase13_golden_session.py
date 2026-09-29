import json
from pathlib import Path
from honda_analyzer.analysis.golden_session import build_golden_session,replay_golden_rows,replay_digest
from honda_analyzer.storage.db import SessionDB

def test_synthetic_sqlite_replay_report_roundtrip(tmp_path):
    dbp=tmp_path/'golden.sqlite'; html=tmp_path/'report.html'
    result=build_golden_session(dbp,html,dt=0.2)
    db=SessionDB(dbp); rows=db.raw_rows(result['session_id'])
    replayed=replay_golden_rows(rows)
    assert len(replayed)==result['analysis']['samples']
    assert replay_digest(rows)==result['raw_sha256']
    assert replayed[0]['speed']==0
    assert any(x['speed']>60 and x['engine_rpm']==0 for x in replayed)
    text=html.read_text()
    assert 'SYNTHETIC ONLY' in text and result['raw_sha256'] in text

def test_golden_is_deterministic_across_databases(tmp_path):
    a=build_golden_session(tmp_path/'a.sqlite',dt=0.2)
    b=build_golden_session(tmp_path/'b.sqlite',dt=0.2)
    assert a['raw_sha256']==b['raw_sha256']
    assert a['analysis']==b['analysis']

def test_recovery_marks_abandoned_session(tmp_path):
    p=tmp_path/'recover.sqlite'; db=SessionDB(p)
    sid=db.create_session('2026-01-01T00:00:00+00:00')
    db2=SessionDB(p); assert sid in db2.recover_open_sessions()
    assert db2.list_sessions()[0][3]=='RECOVERED'
