import json, zipfile
from honda_analyzer.analysis.communication_quality import assess_communication_quality
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.debug_bundle import create_session_debug_bundle
from honda_analyzer.diagnostics import session_diagnostics

def test_quality_good_and_poor():
    q=assess_communication_quality([80,90,100,110],rssi_dbm=-55,total_requests=4)
    assert q.grade=='GOOD' and q.score>=85
    p=assess_communication_quality([600,900,1200],rssi_dbm=-90,timeouts=2,total_requests=5)
    assert p.grade=='POOR' and p.score<65 and p.recommendations

def test_session_scoped_debug_bundle(tmp_path):
    db=SessionDB(tmp_path/'s.db'); s1=db.create_session('t1'); s2=db.create_session('t2')
    db.append_command(s1,'t','ATI',b'ELM327>',12,True); db.append_raw(s1,'t','BLE','x',b'abc'); db.add_event(s1,'t','STOP','note')
    db.append_command(s2,'t','SECRET',b'other-session',1,True); db.add_device(s1,'BLE','adapter-1',{'notify':'1234'})
    q=session_diagnostics(tmp_path/'s.db',s1,rssi_dbm=-60); out=create_session_debug_bundle(tmp_path/'bundle.zip',tmp_path/'s.db',s1,quality=q,tool_version='test')
    with zipfile.ZipFile(out) as z:
        names=set(z.namelist()); assert {'manifest.json','commands.json','ble_devices.json','raw_capture.jsonl','events.json','ui_actions.jsonl'}<=names
        all_text='\n'.join(z.read(n).decode('utf-8','replace') for n in names)
        assert 'ATI' in all_text and 'SECRET' not in all_text and 'other-session' not in all_text
        assert json.loads(z.read('manifest.json'))['scope']=='single-session-only'


def test_quality_no_data_is_not_good():
    q=assess_communication_quality([],total_requests=0)
    assert q.grade=='NO DATA' and q.score==0

def test_timeout_and_no_data_are_classified_separately(tmp_path):
    db=SessionDB(tmp_path/'q.db'); sid=db.create_session('t')
    db.append_command(sid,'t','010C',b'TimeoutError:',0,False)
    db.append_command(sid,'t','222012',b'NO DATA\r>',100,False)
    db.append_command(sid,'t','010D',b'410D00\r>',100,True)
    q=session_diagnostics(tmp_path/'q.db',sid)
    assert q.timeout_rate == 1/3
    assert q.error_rate == 0
