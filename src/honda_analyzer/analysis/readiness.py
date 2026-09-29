from __future__ import annotations
import asyncio, json
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
from pathlib import Path
from honda_analyzer.protocol.elm_session import ElmSession
from honda_analyzer.protocol.elm327 import ElmPromptFramer
from honda_analyzer.protocol.elm_text import find_uds_22_payload
from honda_analyzer.transport.replay import ReplayTransport

UTC=lambda: datetime.now(timezone.utc).isoformat()

@dataclass
class ReadinessCheck:
    name: str
    status: str
    detail: str = ''
    command: str|None = None
    latency_ms: float|None = None
    raw_hex: str = ''

@dataclass
class ReadinessReport:
    started_utc: str
    ended_utc: str
    overall: str
    checks: list[ReadinessCheck]
    metadata: dict

    def to_dict(self):
        d=asdict(self); d['checks']=[asdict(x) for x in self.checks]; return d

    def write_json(self,path):
        Path(path).write_text(json.dumps(self.to_dict(),ensure_ascii=False,indent=2),encoding='utf-8')

    def write_html(self,path):
        import html
        rows=''.join(f'<tr><td>{html.escape(c.name)}</td><td>{c.status}</td><td>{html.escape(c.command or "")}</td><td>{"" if c.latency_ms is None else f"{c.latency_ms:.1f}"}</td><td><pre>{html.escape(c.detail)}</pre></td></tr>' for c in self.checks)
        body=f'''<!doctype html><meta charset="utf-8"><title>Vehicle Readiness</title><h1>Honda e:HEV Vehicle Readiness</h1><p><b>Overall:</b> {self.overall}</p><p>{self.started_utc} → {self.ended_utc}</p><table border="1" cellspacing="0" cellpadding="5"><tr><th>Check</th><th>Status</th><th>Command</th><th>ms</th><th>Detail</th></tr>{rows}</table><h2>Metadata</h2><pre>{html.escape(json.dumps(self.metadata,ensure_ascii=False,indent=2))}</pre>'''
        Path(path).write_text(body,encoding='utf-8')

async def _cmd(session, name, command, timeout=8.0, *, required=True):
    try:
        r=await session.command(command,timeout=timeout)
        if r.success:
            status='PASS'
        else:
            status='FAIL' if required else 'WARN'
        return ReadinessCheck(name,status,r.text,command,r.latency_ms,r.raw.hex())
    except asyncio.TimeoutError:
        return ReadinessCheck(name,'FAIL' if required else 'WARN','TIMEOUT',command)
    except Exception as e:
        return ReadinessCheck(name,'FAIL' if required else 'WARN',f'{type(e).__name__}: {e}',command)

async def run_vehicle_readiness(transport, *, db=None, session_id=None, reconnect=True, replay_verify=True):
    """Conservative first-vehicle acceptance gate. No DID scan is performed.

    Adapter formatting/protocol state is established here so the result does not
    depend on whatever state a previous app left in the ELM-compatible adapter.
    Vehicle-specific 019A/2012 support is WARN-only; base OBD/setup/reconnect and
    parser replay are hard requirements.
    """
    started=UTC(); checks=[]; metadata={'read_only_sequence':True,'did_scan_performed':False}
    try:
        await transport.connect(); checks.append(ReadinessCheck('Transport connect','PASS'))
    except Exception as e:
        checks.append(ReadinessCheck('Transport connect','FAIL',f'{type(e).__name__}: {e}'))
        return ReadinessReport(started,UTC(),'FAIL',checks,metadata)
    if hasattr(transport,'gatt'):
        gatt=getattr(transport,'gatt',[]) or []
        metadata['gatt_count']=len(gatt); metadata['write_char']=getattr(transport,'write_char',None); metadata['notify_char']=getattr(transport,'notify_char',None); metadata['mtu_size']=getattr(transport,'mtu_size',None); metadata['scan_rssi_dbm']=getattr(transport,'scan_rssi_dbm',None)
        if hasattr(transport,'inspector_snapshot'):
            metadata['gatt']=transport.inspector_snapshot()
        checks.append(ReadinessCheck('GATT discovery','PASS' if gatt or metadata['write_char'] else 'WARN',f'{len(gatt)} characteristics; MTU={metadata.get("mtu_size")}'))
        if db is not None and session_id is not None and hasattr(db,'add_device'):
            try:
                db.add_device(session_id,'BLE',getattr(transport,'device_id','UNKNOWN'),{k:metadata.get(k) for k in ('write_char','notify_char','mtu_size','scan_rssi_dbm','gatt')})
            except Exception as e:
                checks.append(ReadinessCheck('Persist GATT metadata','WARN',f'{type(e).__name__}: {e}'))
    session=ElmSession(transport)
    # Do not inherit unknown adapter state. These are adapter configuration only.
    setup=[
        ('ELM reset','ATZ',True),('Echo off','ATE0',True),('Linefeeds off','ATL0',True),
        ('Spaces off','ATS0',True),('Headers on','ATH1',True),('Long messages','ATAL',True),
        ('CAN auto formatting','ATCAF1',True),('CAN flow control','ATCFC1',True),
        ('Protocol 7: ISO15765 29/500','ATSP7',True),
    ]
    sequence=[
        ('Adapter identity','ATI',True),('CAN protocol','ATDP',True),('CAN protocol number','ATDPN',True),
        ('CAN priority 18','ATCP18',True),('OBD functional header','ATSHDB33F1',True),('RPM','010C',True),('Vehicle speed','010D',True),('Coolant','0105',True),
        ('Hybrid/EV PID 9A raw','019A',False),('Headers on','ATH1',True),('UDS functional header','ATSHDBEFF1',True),
        ('Honda DID 2012 raw','222012',False),
    ]
    command_results=[]
    for name,cmd,required in setup+sequence:
        c=await _cmd(session,name,cmd,required=required); checks.append(c); command_results.append(c)
        if db is not None and session_id is not None:
            raw=bytes.fromhex(c.raw_hex) if c.raw_hex else c.detail.encode('utf-8','replace')
            db.append_command(session_id,UTC(),cmd,raw,c.latency_ms or 0.0,c.status=='PASS')
    did=next((x for x in checks if x.command=='222012'),None)
    if did and did.raw_hex:
        hit=find_uds_22_payload(did.detail,0x2012)
        positive=hit is not None
        checks.append(ReadinessCheck('DID 2012 positive response','PASS' if positive else 'WARN','Expected positive response 62 20 12; raw retained'))
        can_id=hit[1] if hit else None
        checks.append(ReadinessCheck('Response CAN ID observed','PASS' if can_id else 'WARN',can_id or 'No response header parsed; inspect RAW'))
        if can_id: metadata['response_can_id']=can_id
    else:
        checks.append(ReadinessCheck('DID 2012 positive response','WARN','No positive DID 2012 payload; raw/error retained'))
        checks.append(ReadinessCheck('Response CAN ID observed','WARN','No DID 2012 response CAN ID observed'))
    if reconnect:
        try:
            await transport.disconnect(); await transport.connect(); rs=ElmSession(transport); r=await rs.command('ATI',timeout=8)
            checks.append(ReadinessCheck('Disconnect / reconnect','PASS' if r.success else 'FAIL',r.text,'ATI',r.latency_ms,r.raw.hex()))
        except Exception as e: checks.append(ReadinessCheck('Disconnect / reconnect','FAIL',f'{type(e).__name__}: {e}'))
    try: await transport.disconnect()
    except Exception: pass
    if replay_verify:
        try:
            items=[(started,'ELM','readiness-capture',bytes.fromhex(c.raw_hex)) for c in command_results if c.raw_hex]
            if items:
                rt=ReplayTransport(items,speed=float('inf')); await rt.connect(); seen=[]; parser=ElmPromptFramer(); parser_ok=True
                while True:
                    try:
                        chunk=(await asyncio.wait_for(rt.recv(),0.01)).data; seen.append(chunk)
                        framed=parser.feed(chunk)
                        if len(framed)!=1 or framed[0].raw!=chunk: parser_ok=False
                    except (asyncio.TimeoutError,EOFError): break
                await rt.disconnect()
                bytes_ok=len(seen)==len(items) and all(a[3]==b for a,b in zip(items,seen))
                ok=bytes_ok and parser_ok and not parser.pending
                checks.append(ReadinessCheck('Replay parser byte identity','PASS' if ok else 'FAIL',f'{len(seen)}/{len(items)} responses; parser={"OK" if parser_ok else "FAIL"}'))
            else: checks.append(ReadinessCheck('Replay parser byte identity','FAIL','No response bytes captured'))
        except Exception as e: checks.append(ReadinessCheck('Replay parser byte identity','FAIL',f'{type(e).__name__}: {e}'))
    hard=[x for x in checks if x.status=='FAIL']; warns=[x for x in checks if x.status=='WARN']
    overall='FAIL' if hard else ('WARN' if warns else 'PASS')
    metadata['pass_count']=sum(x.status=='PASS' for x in checks); metadata['warn_count']=len(warns); metadata['fail_count']=len(hard)
    return ReadinessReport(started,UTC(),overall,checks,metadata)
