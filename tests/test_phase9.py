import json, zipfile
from honda_analyzer.transport.faults import Fault,FaultInjector
from honda_analyzer.analysis.timing import timing_stats
from honda_analyzer.analysis.scheduler import PollItem,simulate,recommend_rate
from honda_analyzer.debug_bundle import create_debug_bundle

def rows(): return [('2026-01-01T00:00:00+00:00','BLE','x',b'abc'),('2026-01-01T00:00:01+00:00','BLE','x',b'def')]

def test_faults_are_deterministic():
    f=FaultInjector([Fault('split',0,1),Fault('duplicate',1)])
    assert f.apply(rows())==f.apply(rows())
    assert [x[3] for x in f.apply(rows())]==[b'a',b'bc',b'def',b'def']

def test_fault_error_substitution():
    assert FaultInjector([Fault('elm_no_data',0)]).apply(rows())[0][3]==b'NO DATA\r>'
    assert len(FaultInjector([Fault('drop',0)]).apply(rows()))==1

def test_timing_stats():
    s=timing_stats([10,20,30,40],2,notifications=10,byte_count=100)
    assert s['average_ms']==25 and s['request_per_s']==2 and s['bytes_per_s']==50

def test_scheduler_and_rate():
    r=simulate([PollItem('rpm',100,20),PollItem('speed',100,20)],1000)
    assert r['utilization']==.4 and not r['overloaded'] and r['signals']['rpm']['achievable_hz']==10
    assert recommend_rate([100]*20)==7

def test_scheduler_detects_overload():
    r=simulate([PollItem('a',100,80),PollItem('b',100,80)],1000); assert r['overloaded'] and r['signals']['b']['deadline_miss']>0

def test_debug_bundle_is_explicit(tmp_path):
    log=tmp_path/'application.log';log.write_text('ok')
    raw=tmp_path/'session.raw';raw.write_bytes(b'RAW')
    secret=tmp_path/'other_session.raw';secret.write_bytes(b'SECRET')
    z=create_debug_bundle(tmp_path/'d.zip',app_log=log,metadata={'session':1},raw_files=[raw],tool_version='x')
    with zipfile.ZipFile(z) as q:
        assert 'raw/session.raw' in q.namelist() and 'raw/other_session.raw' not in q.namelist()
        assert json.loads(q.read('manifest.json'))['metadata']['session']==1
