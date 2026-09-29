import sqlite3, json
from pathlib import Path
SCHEMA="""
PRAGMA journal_mode=WAL; PRAGMA synchronous=FULL;
CREATE TABLE IF NOT EXISTS sessions(id INTEGER PRIMARY KEY, started_utc TEXT NOT NULL, ended_utc TEXT, status TEXT NOT NULL, git_commit TEXT, tool_version TEXT, vehicle TEXT, notes TEXT);
CREATE TABLE IF NOT EXISTS raw_capture(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, layer TEXT NOT NULL, source TEXT NOT NULL, payload BLOB NOT NULL, FOREIGN KEY(session_id) REFERENCES sessions(id));
CREATE TABLE IF NOT EXISTS commands(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, command TEXT NOT NULL, raw_response BLOB, latency_ms REAL, success INTEGER);
CREATE TABLE IF NOT EXISTS did_responses(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, ecu TEXT, response_can_id TEXT, did INTEGER NOT NULL, positive INTEGER NOT NULL, nrc INTEGER, payload BLOB NOT NULL);
CREATE TABLE IF NOT EXISTS events(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, kind TEXT NOT NULL, note TEXT);
CREATE TABLE IF NOT EXISTS devices(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, kind TEXT, identifier TEXT, metadata_json TEXT);
CREATE TABLE IF NOT EXISTS ui_actions(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, action TEXT NOT NULL, detail TEXT);
CREATE INDEX IF NOT EXISTS idx_raw_session_ts ON raw_capture(session_id,ts_utc);
CREATE INDEX IF NOT EXISTS idx_did ON did_responses(session_id,did,ecu);
CREATE INDEX IF NOT EXISTS idx_ui_actions_session_ts ON ui_actions(session_id,ts_utc);
CREATE TABLE IF NOT EXISTS ecus(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, request_can_id TEXT, response_can_id TEXT, first_seen_utc TEXT, UNIQUE(session_id,ecu,response_can_id));
CREATE TABLE IF NOT EXISTS did_scan(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, status TEXT NOT NULL, latency_ms REAL, nrc INTEGER, payload BLOB, response_can_id TEXT, updated_utc TEXT NOT NULL, UNIQUE(session_id,ecu,did));
CREATE INDEX IF NOT EXISTS idx_did_scan_resume ON did_scan(session_id,ecu,status,did);
CREATE TABLE IF NOT EXISTS did_drive_plan(session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, discovered_session_id INTEGER, created_utc TEXT NOT NULL, PRIMARY KEY(session_id,ecu,did));
CREATE TABLE IF NOT EXISTS did_drive_samples(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, response_can_id TEXT, payload BLOB NOT NULL, latency_ms REAL, success INTEGER NOT NULL DEFAULT 1, partial INTEGER NOT NULL DEFAULT 0);
CREATE INDEX IF NOT EXISTS idx_did_drive_samples ON did_drive_samples(session_id,ecu,did,ts_utc);
"""
class SessionDB:
 def __init__(self,path):
  self.path=Path(path);self.conn=sqlite3.connect(self.path);self.conn.executescript(SCHEMA)
  cols={r[1] for r in self.conn.execute('PRAGMA table_info(did_drive_samples)')}
  if 'partial' not in cols:self.conn.execute('ALTER TABLE did_drive_samples ADD COLUMN partial INTEGER NOT NULL DEFAULT 0');self.conn.commit()
 def create_session(self,started_utc,git_commit=None,tool_version=None,vehicle='Honda STEP WGN RP8 e:HEV'):
  c=self.conn.execute("INSERT INTO sessions(started_utc,status,git_commit,tool_version,vehicle) VALUES(?,?,?,?,?)",(started_utc,'OPEN',git_commit,tool_version,vehicle));self.conn.commit();return c.lastrowid
 def append_raw(self,sid,ts,layer,source,payload): self.conn.execute("INSERT INTO raw_capture(session_id,ts_utc,layer,source,payload) VALUES(?,?,?,?,?)",(sid,ts,layer,source,sqlite3.Binary(payload)));self.conn.commit()
 def append_command(self,sid,ts,command,raw,latency_ms,success): self.conn.execute("INSERT INTO commands(session_id,ts_utc,command,raw_response,latency_ms,success) VALUES(?,?,?,?,?,?)",(sid,ts,command,sqlite3.Binary(raw),latency_ms,int(success)));self.conn.commit()
 def add_event(self,sid,ts,kind,note=None): self.conn.execute("INSERT INTO events(session_id,ts_utc,kind,note) VALUES(?,?,?,?)",(sid,ts,kind,note));self.conn.commit()
 def add_device(self,sid,kind,identifier,metadata): self.conn.execute("INSERT INTO devices(session_id,kind,identifier,metadata_json) VALUES(?,?,?,?)",(sid,kind,identifier,json.dumps(metadata,ensure_ascii=False)));self.conn.commit()
 def add_ui_action(self,sid,ts,action,detail=None): self.conn.execute("INSERT INTO ui_actions(session_id,ts_utc,action,detail) VALUES(?,?,?,?)",(sid,ts,action,detail));self.conn.commit()
 def close_session(self,sid,ended_utc,status='CLOSED'): self.conn.execute("UPDATE sessions SET ended_utc=?,status=? WHERE id=?",(ended_utc,status,sid));self.conn.commit()
 def recover_open_sessions(self):
  rows=self.conn.execute("SELECT id FROM sessions WHERE status='OPEN'").fetchall();ids=[x[0] for x in rows]
  self.conn.executemany("UPDATE sessions SET status='RECOVERED' WHERE id=?",[(i,) for i in ids]);self.conn.commit();return ids
 def list_sessions(self): return self.conn.execute("SELECT id,started_utc,ended_utc,status,git_commit,vehicle,notes FROM sessions ORDER BY id DESC").fetchall()
 def raw_rows(self,sid): return self.conn.execute("SELECT ts_utc,layer,source,payload FROM raw_capture WHERE session_id=? ORDER BY id",(sid,)).fetchall()

# Phase 5 schema migration kept additive for existing Phase 1-4 databases.
def _phase5_schema(conn):
 conn.executescript("""
 CREATE TABLE IF NOT EXISTS ecus(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, request_can_id TEXT, response_can_id TEXT, first_seen_utc TEXT, UNIQUE(session_id,ecu,response_can_id));
 CREATE TABLE IF NOT EXISTS did_scan(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, status TEXT NOT NULL, latency_ms REAL, nrc INTEGER, payload BLOB, response_can_id TEXT, updated_utc TEXT NOT NULL, UNIQUE(session_id,ecu,did));
 CREATE INDEX IF NOT EXISTS idx_did_scan_resume ON did_scan(session_id,ecu,status,did);
 """)
 conn.commit()

SessionDB._phase5_schema = lambda self: _phase5_schema(self.conn)

def _save_scan(self,sid,ecu,did,status,updated_utc,latency_ms=None,nrc=None,payload=b'',response_can_id=None):
 _phase5_schema(self.conn)
 self.conn.execute("INSERT INTO did_scan(session_id,ecu,did,status,latency_ms,nrc,payload,response_can_id,updated_utc) VALUES(?,?,?,?,?,?,?,?,?) ON CONFLICT(session_id,ecu,did) DO UPDATE SET status=excluded.status,latency_ms=excluded.latency_ms,nrc=excluded.nrc,payload=excluded.payload,response_can_id=excluded.response_can_id,updated_utc=excluded.updated_utc",(sid,ecu,did,getattr(status,'value',str(status)),latency_ms,nrc,sqlite3.Binary(payload),response_can_id,updated_utc)); self.conn.commit()
SessionDB.save_scan_result=_save_scan

def _completed_dids(self,sid,ecu):
 _phase5_schema(self.conn)
 return {r[0] for r in self.conn.execute("SELECT did FROM did_scan WHERE session_id=? AND ecu=? AND (status IN ('positive','positive_partial') OR (status='nrc' AND nrc=49))",(sid,ecu))}
SessionDB.completed_dids=_completed_dids

def _positive_dids(self,sid,ecu=None):
 _phase5_schema(self.conn)
 if ecu is None: return self.conn.execute("SELECT ecu,did,payload,response_can_id FROM did_scan WHERE session_id=? AND status IN ('positive','positive_partial') ORDER BY ecu,did",(sid,)).fetchall()
 return self.conn.execute("SELECT ecu,did,payload,response_can_id FROM did_scan WHERE session_id=? AND ecu=? AND status IN ('positive','positive_partial') ORDER BY did",(sid,ecu)).fetchall()
SessionDB.positive_dids=_positive_dids

def _command_rows(self,sid,command=None):
 if command is None:return self.conn.execute("SELECT ts_utc,command,raw_response,latency_ms,success FROM commands WHERE session_id=? ORDER BY id",(sid,)).fetchall()
 return self.conn.execute("SELECT ts_utc,command,raw_response,latency_ms,success FROM commands WHERE session_id=? AND REPLACE(command,' ','')=REPLACE(?,' ','') ORDER BY id",(sid,command)).fetchall()
SessionDB.command_rows=_command_rows

def _session_started(self,sid):
 r=self.conn.execute("SELECT started_utc FROM sessions WHERE id=?",(sid,)).fetchone(); return r[0] if r else None
SessionDB.session_started=_session_started


def _event_rows(self,sid):
 return self.conn.execute("SELECT ts_utc,kind,note FROM events WHERE session_id=? ORDER BY id",(sid,)).fetchall()
SessionDB.event_rows=_event_rows

def _session_row(self,sid):
 return self.conn.execute("SELECT id,started_utc,ended_utc,status,git_commit,tool_version,vehicle,notes FROM sessions WHERE id=?",(sid,)).fetchone()
SessionDB.session_row=_session_row


def _session_counts(self,sid):
 _phase5_schema(self.conn); _phase31_schema(self.conn) if '_phase31_schema' in globals() else None
 return {
  'raw': self.conn.execute("SELECT COUNT(*) FROM raw_capture WHERE session_id=?",(sid,)).fetchone()[0],
  'commands': self.conn.execute("SELECT COUNT(*) FROM commands WHERE session_id=?",(sid,)).fetchone()[0],
  'events': self.conn.execute("SELECT COUNT(*) FROM events WHERE session_id=?",(sid,)).fetchone()[0],
  'devices': self.conn.execute("SELECT COUNT(*) FROM devices WHERE session_id=?",(sid,)).fetchone()[0],
  'ui_actions': self.conn.execute("SELECT COUNT(*) FROM ui_actions WHERE session_id=?",(sid,)).fetchone()[0],
  'did_scan': self.conn.execute("SELECT COUNT(*) FROM did_scan WHERE session_id=?",(sid,)).fetchone()[0],
  'did_drive_samples': self.conn.execute("SELECT COUNT(*) FROM did_drive_samples WHERE session_id=?",(sid,)).fetchone()[0] if '_phase31_schema' in globals() else 0,
 }
SessionDB.session_counts=_session_counts

def _session_has_evidence(self,sid):
 c=_session_counts(self,sid)
 return any(c.get(k,0) for k in ('raw','commands','events','devices','did_scan','did_drive_samples'))
SessionDB.session_has_evidence=_session_has_evidence

def _ui_action_rows(self,sid):
 return self.conn.execute("SELECT ts_utc,action,detail FROM ui_actions WHERE session_id=? ORDER BY id",(sid,)).fetchall()
SessionDB.ui_action_rows=_ui_action_rows


def _discard_session_if_empty(self,sid):
 if _session_has_evidence(self,sid):
  return False
 self.conn.execute("DELETE FROM ui_actions WHERE session_id=?",(sid,))
 self.conn.execute("DELETE FROM sessions WHERE id=?",(sid,))
 self.conn.commit()
 return True
SessionDB.discard_session_if_empty=_discard_session_if_empty


# Phase 31: cross-session DID discovery + drive-sweep persistence.
def _phase31_schema(conn):
 conn.executescript("""
 CREATE TABLE IF NOT EXISTS did_drive_plan(session_id INTEGER NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, discovered_session_id INTEGER, created_utc TEXT NOT NULL, PRIMARY KEY(session_id,ecu,did));
 CREATE TABLE IF NOT EXISTS did_drive_samples(id INTEGER PRIMARY KEY, session_id INTEGER NOT NULL, ts_utc TEXT NOT NULL, ecu TEXT NOT NULL, did INTEGER NOT NULL, response_can_id TEXT, payload BLOB NOT NULL, latency_ms REAL, success INTEGER NOT NULL DEFAULT 1, partial INTEGER NOT NULL DEFAULT 0);
 CREATE INDEX IF NOT EXISTS idx_did_drive_samples ON did_drive_samples(session_id,ecu,did,ts_utc);
 """)
 cols={r[1] for r in conn.execute("PRAGMA table_info(did_drive_samples)")}
 if 'partial' not in cols:
  conn.execute("ALTER TABLE did_drive_samples ADD COLUMN partial INTEGER NOT NULL DEFAULT 0")
 conn.commit()
SessionDB._phase31_schema=lambda self:_phase31_schema(self.conn)


def _completed_dids_global(self,ecu,start=0,end=0xFFFF):
 _phase5_schema(self.conn)
 # Positive is definitive. NRC 0x31 (requestOutOfRange) is treated as checked.
 # Other NRCs, NO DATA and timeouts remain retryable on a later stationary scan.
 rows=self.conn.execute("""
  SELECT DISTINCT did FROM did_scan
  WHERE ecu=? AND did BETWEEN ? AND ? AND (status IN ('positive','positive_partial') OR (status='nrc' AND nrc=49))
 """,(str(ecu).upper(),int(start),int(end))).fetchall()
 return {int(r[0]) for r in rows}
SessionDB.completed_dids_global=_completed_dids_global


def _positive_did_inventory(self,ecus=None):
 _phase5_schema(self.conn)
 params=[]; where="status IN ('positive','positive_partial')"
 if ecus:
  vals=[str(x).upper() for x in ecus]
  where += ' AND ecu IN ('+','.join('?' for _ in vals)+')'; params.extend(vals)
 q=f"""
 SELECT ds.ecu,ds.did,ds.payload,ds.response_can_id,ds.session_id
 FROM did_scan ds
 JOIN (SELECT ecu,did,MAX(id) AS max_id FROM did_scan WHERE {where} GROUP BY ecu,did) x ON ds.id=x.max_id
 ORDER BY CAST('0x'||ds.ecu AS INTEGER),ds.ecu,ds.did
 """
 # SQLite CAST of 0x text is implementation-specific; ordering by ecu string is deterministic enough.
 q=q.replace("ORDER BY CAST('0x'||ds.ecu AS INTEGER),ds.ecu,ds.did","ORDER BY ds.ecu,ds.did")
 return self.conn.execute(q,tuple(params)).fetchall()
SessionDB.positive_did_inventory=_positive_did_inventory


def _positive_did_inventory_detailed(self,ecus=None):
 _phase5_schema(self.conn)
 params=[]; where="status IN ('positive','positive_partial')"
 if ecus:
  vals=[str(x).upper() for x in ecus]
  where += ' AND ecu IN ('+','.join('?' for _ in vals)+')'; params.extend(vals)
 q=f"""
 SELECT ds.ecu,ds.did,ds.status,ds.payload,ds.response_can_id,ds.session_id
 FROM did_scan ds
 JOIN (SELECT ecu,did,MAX(id) AS max_id FROM did_scan WHERE {where} GROUP BY ecu,did) x ON ds.id=x.max_id
 ORDER BY ds.ecu,ds.did
 """
 return self.conn.execute(q,tuple(params)).fetchall()
SessionDB.positive_did_inventory_detailed=_positive_did_inventory_detailed


def _save_did_drive_plan(self,sid,items,created_utc):
 _phase31_schema(self.conn)
 self.conn.executemany("INSERT OR REPLACE INTO did_drive_plan(session_id,ecu,did,discovered_session_id,created_utc) VALUES(?,?,?,?,?)",[(sid,str(ecu).upper(),int(did),disc_sid,created_utc) for ecu,did,_payload,_rid,disc_sid in items])
 self.conn.commit()
SessionDB.save_did_drive_plan=_save_did_drive_plan


def _did_drive_plan(self,sid):
 _phase31_schema(self.conn)
 return self.conn.execute("SELECT ecu,did,discovered_session_id,created_utc FROM did_drive_plan WHERE session_id=? ORDER BY ecu,did",(sid,)).fetchall()
SessionDB.did_drive_plan=_did_drive_plan


def _append_did_drive_sample(self,sid,ts,ecu,did,response_can_id,payload,latency_ms=None,success=True,partial=False):
 _phase31_schema(self.conn)
 self.conn.execute("INSERT INTO did_drive_samples(session_id,ts_utc,ecu,did,response_can_id,payload,latency_ms,success,partial) VALUES(?,?,?,?,?,?,?,?,?)",(sid,ts,str(ecu).upper(),int(did),response_can_id,sqlite3.Binary(bytes(payload)),latency_ms,int(bool(success)),int(bool(partial))))
 self.conn.commit()
SessionDB.append_did_drive_sample=_append_did_drive_sample


def _did_drive_rows(self,sid,success_only=True):
 _phase31_schema(self.conn)
 q="SELECT ts_utc,ecu,did,payload,response_can_id,latency_ms,success,partial FROM did_drive_samples WHERE session_id=?"
 if success_only:q += " AND success=1"
 q += " ORDER BY id"
 return self.conn.execute(q,(sid,)).fetchall()
SessionDB.did_drive_rows=_did_drive_rows


def _did_drive_coverage(self,sid):
 _phase31_schema(self.conn)
 return self.conn.execute("""
 SELECT p.ecu,p.did,COUNT(s.id),COUNT(DISTINCT hex(s.payload)),MIN(length(s.payload)),MAX(length(s.payload)),COALESCE(SUM(s.partial),0)
 FROM did_drive_plan p
 LEFT JOIN did_drive_samples s ON s.session_id=p.session_id AND s.ecu=p.ecu AND s.did=p.did AND s.success=1
 WHERE p.session_id=? GROUP BY p.ecu,p.did ORDER BY p.ecu,p.did
 """,(sid,)).fetchall()
SessionDB.did_drive_coverage=_did_drive_coverage
