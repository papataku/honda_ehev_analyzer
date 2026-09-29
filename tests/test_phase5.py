from datetime import datetime, timezone
from honda_analyzer.analysis.discovery import response_ecu_from_29bit, parse_elm_header_line
from honda_analyzer.analysis.did_scanner import DidScanner, ScanStatus
from honda_analyzer.storage.db import SessionDB

class Client:
 def read_did(self,ecu,req):
  did=int.from_bytes(req[1:],'big')
  if did==0x2012: return bytes.fromhex('6220120102'),'18DAF116'
  return bytes.fromhex('7F2231'),'18DAF116'

def test_ecu_discovery_helpers():
 assert response_ecu_from_29bit('18DAF116')=='16'
 r=parse_elm_header_line('18DAF116 62 20 12 01 02')
 assert r and r.positive and r.did==0x2012 and r.ecu=='16'

def test_scanner_only_builds_22_and_stops_on_speed():
 seen=[]
 s=DidScanner(Client(),seen.append,lambda:0)
 rows=list(s.scan('16',0x2011,0x2012,rate_hz=10000))
 assert rows[0].status==ScanStatus.NRC and rows[1].status==ScanStatus.POSITIVE
 s2=DidScanner(Client(),seen.append,lambda:1)
 assert list(s2.scan('16',0x2000,0x2001,10000))[0].status==ScanStatus.STOPPED_SPEED

def test_scan_resume_db(tmp_path):
 db=SessionDB(tmp_path/'x.db'); sid=db.create_session(datetime.now(timezone.utc).isoformat())
 db.save_scan_result(sid,'16',0x2012,'positive',datetime.now(timezone.utc).isoformat(),12,None,b'xx','18DAF116')
 assert 0x2012 in db.completed_dids(sid,'16')
 assert db.positive_dids(sid,'16')[0][1]==0x2012
