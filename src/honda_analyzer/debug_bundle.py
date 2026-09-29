from __future__ import annotations
import json, platform, sqlite3, sys, zipfile
from pathlib import Path
from honda_analyzer.build_info import BUILD_ID, SOURCE_HASH

def create_debug_bundle(dest, *, app_log=None, metadata=None, elm_init=None, ble_info=None, config_files=(), raw_files=(), tool_version='unknown'):
    """Create an explicit, session-scoped bundle. Caller chooses raw files; no directory crawling."""
    dest=Path(dest); manifest={'tool_version':tool_version,'build_id':BUILD_ID,'source_hash':SOURCE_HASH,'python':sys.version,'macOS':platform.platform(),'metadata':metadata or {},'elm_initialization':elm_init or [],'ble_information':ble_info or {}}
    with zipfile.ZipFile(dest,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False,indent=2,default=str))
        if app_log and Path(app_log).is_file(): z.write(app_log,'application.log')
        for group,paths in [('config',config_files),('raw',raw_files)]:
            for p in paths:
                p=Path(p)
                if p.is_file(): z.write(p,f'{group}/{p.name}')
    return dest

def create_session_debug_bundle(dest, db_path, session_id, *, app_log=None, config_files=(), tool_version='unknown', quality=None):
    """Export only one selected session. Other sessions and unrelated personal data are excluded."""
    db_path=Path(db_path); conn=sqlite3.connect(db_path)
    session=conn.execute('SELECT id,started_utc,ended_utc,status,git_commit,tool_version,vehicle,notes FROM sessions WHERE id=?',(session_id,)).fetchone()
    if not session: conn.close(); raise ValueError(f'Unknown session {session_id}')
    cols=['id','started_utc','ended_utc','status','git_commit','tool_version','vehicle','notes']; meta=dict(zip(cols,session))
    commands=[{'ts_utc':a,'command':b,'raw_response_hex':(c or b'').hex(),'latency_ms':d,'success':bool(e)} for a,b,c,d,e in conn.execute('SELECT ts_utc,command,raw_response,latency_ms,success FROM commands WHERE session_id=? ORDER BY id',(session_id,))]
    devices=[{'kind':a,'identifier':b,'metadata':json.loads(c or '{}')} for a,b,c in conn.execute('SELECT kind,identifier,metadata_json FROM devices WHERE session_id=? ORDER BY id',(session_id,))]
    raw=[{'ts_utc':a,'layer':b,'source':c,'payload_hex':d.hex()} for a,b,c,d in conn.execute('SELECT ts_utc,layer,source,payload FROM raw_capture WHERE session_id=? ORDER BY id',(session_id,))]
    events=[{'ts_utc':a,'kind':b,'note':c} for a,b,c in conn.execute('SELECT ts_utc,kind,note FROM events WHERE session_id=? ORDER BY id',(session_id,))]
    try:
        ui_actions=[{'ts_utc':a,'action':b,'detail':c} for a,b,c in conn.execute('SELECT ts_utc,action,detail FROM ui_actions WHERE session_id=? ORDER BY id',(session_id,))]
    except sqlite3.OperationalError:
        ui_actions=[]
    try:
        did_scan=[{'ecu':a,'did':b,'status':c,'latency_ms':d,'nrc':e,'payload_hex':(f or b'').hex(),'response_can_id':g,'updated_utc':h} for a,b,c,d,e,f,g,h in conn.execute('SELECT ecu,did,status,latency_ms,nrc,payload,response_can_id,updated_utc FROM did_scan WHERE session_id=? ORDER BY ecu,did',(session_id,))]
    except sqlite3.OperationalError:
        did_scan=[]
    try:
        did_plan=[{'ecu':a,'did':b,'discovered_session_id':c,'created_utc':d} for a,b,c,d in conn.execute('SELECT ecu,did,discovered_session_id,created_utc FROM did_drive_plan WHERE session_id=? ORDER BY ecu,did',(session_id,))]
        cols={r[1] for r in conn.execute('PRAGMA table_info(did_drive_samples)')}
        if 'partial' in cols:
            did_samples=[{'ts_utc':a,'ecu':b,'did':c,'response_can_id':d,'payload_hex':(e or b'').hex(),'latency_ms':f,'success':bool(g),'partial':bool(h)} for a,b,c,d,e,f,g,h in conn.execute('SELECT ts_utc,ecu,did,response_can_id,payload,latency_ms,success,partial FROM did_drive_samples WHERE session_id=? ORDER BY id',(session_id,))]
        else:
            did_samples=[{'ts_utc':a,'ecu':b,'did':c,'response_can_id':d,'payload_hex':(e or b'').hex(),'latency_ms':f,'success':bool(g),'partial':False} for a,b,c,d,e,f,g in conn.execute('SELECT ts_utc,ecu,did,response_can_id,payload,latency_ms,success FROM did_drive_samples WHERE session_id=? ORDER BY id',(session_id,))]
    except sqlite3.OperationalError:
        did_plan=[]; did_samples=[]
    conn.close()
    manifest={'tool_version':tool_version,'build_id':BUILD_ID,'source_hash':SOURCE_HASH,'python':sys.version,'macOS':platform.platform(),'session':meta,'quality':quality.to_dict() if quality else None,'scope':'single-session-only'}
    dest=Path(dest); dest.parent.mkdir(parents=True,exist_ok=True)
    with zipfile.ZipFile(dest,'w',zipfile.ZIP_DEFLATED) as z:
        z.writestr('manifest.json',json.dumps(manifest,ensure_ascii=False,indent=2,default=str)); z.writestr('commands.json',json.dumps(commands,ensure_ascii=False,indent=2)); z.writestr('ble_devices.json',json.dumps(devices,ensure_ascii=False,indent=2)); z.writestr('raw_capture.jsonl',''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in raw)); z.writestr('events.json',json.dumps(events,ensure_ascii=False,indent=2)); z.writestr('ui_actions.jsonl',''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in ui_actions)); z.writestr('did_scan.json',json.dumps(did_scan,ensure_ascii=False,indent=2)); z.writestr('did_drive_plan.json',json.dumps(did_plan,ensure_ascii=False,indent=2)); z.writestr('did_drive_samples.jsonl',''.join(json.dumps(x,ensure_ascii=False)+'\n' for x in did_samples))
        if app_log and Path(app_log).is_file(): z.write(app_log,'application.log')
        for p in config_files:
            p=Path(p)
            if p.is_file(): z.write(p,f'config/{p.name}')
    return dest
