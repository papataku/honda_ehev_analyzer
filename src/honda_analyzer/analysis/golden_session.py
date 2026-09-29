from __future__ import annotations
import hashlib, json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from .drive_cycle import generate_drive_cycle
from .state_classifier import classify
from .e2e import run_synthetic_e2e
from ..storage.db import SessionDB
from ..export.report import write_html_report

RAW_FORMAT_VERSION = 1

def _iso(base: datetime, seconds: float) -> str:
    return (base + timedelta(seconds=seconds)).isoformat()

def _sample_payload(s) -> bytes:
    # Synthetic canonical payload for regression only. No Honda semantics.
    obj = {"t":round(s.t,6),"speed":s.speed,"engine_rpm":s.engine_rpm,
           "hv_power":s.hv_power,"motor_rpm":s.motor_rpm,"generator_rpm":s.generator_rpm}
    return (json.dumps(obj, sort_keys=True, separators=(",", ":"))+"\n").encode()

def build_golden_session(db_path, report_path=None, dt=0.1):
    db=SessionDB(db_path); db.recover_open_sessions()
    base=datetime(2026,1,1,tzinfo=timezone.utc)
    sid=db.create_session(base.isoformat(),git_commit='SYNTHETIC-GOLDEN',tool_version='phase13',vehicle='SYNTHETIC - NOT VEHICLE EVIDENCE')
    samples=generate_drive_cycle(dt); labels=classify(samples)
    last=None
    for s,states in zip(samples,labels):
        ts=_iso(base,s.t); payload=_sample_payload(s)
        db.append_raw(sid,ts,'synthetic','golden-drive-cycle',payload)
        primary=next((x for x in ['STOP','ACCEL','CRUISE','REGEN','MOVING'] if x in states),None)
        if primary and primary!=last:
            db.add_event(sid,ts,primary,'AUTO-SYNTHETIC')
            last=primary
    ended=_iso(base,samples[-1].t if samples else 0); db.close_session(sid,ended)
    rows=db.raw_rows(sid)
    digest=hashlib.sha256(b''.join(r[3] for r in rows)).hexdigest()
    analysis=run_synthetic_e2e(dt)
    summary={
      'title':'Synthetic Golden Session Report',
      'evidence_warning':'SYNTHETIC ONLY — MUST NOT be used as Honda RP8 signal evidence.',
      'session':{'id':sid,'raw_rows':len(rows),'duration_s':analysis['duration_s'],'raw_sha256':digest},
      'states':analysis['states'], 'motor_candidate':analysis['motor_candidate'],
      'generator_candidate':analysis['generator_candidate'], 'motor_stats':analysis['motor_stats'],
    }
    if report_path: write_html_report(report_path,summary)
    return {'session_id':sid,'raw_sha256':digest,'analysis':analysis,'summary':summary}

def replay_golden_rows(rows):
    """Parse persisted synthetic RAW exactly as replay input; deterministic and side-effect free."""
    out=[]
    for ts,layer,source,payload in rows:
        if layer!='synthetic': continue
        out.append(json.loads(bytes(payload).decode()))
    return out

def replay_digest(rows):
    return hashlib.sha256(b''.join(bytes(r[3]) for r in rows if r[1]=='synthetic')).hexdigest()
