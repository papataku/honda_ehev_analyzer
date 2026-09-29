from __future__ import annotations
import asyncio, platform, sys, tempfile
from datetime import datetime, timezone
from pathlib import Path
from importlib.util import find_spec
from honda_analyzer.analysis.readiness import run_vehicle_readiness
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport, ElmSimulatorProfile
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.storage.async_writer import AsyncSessionWriter
from honda_analyzer.analysis.offline_replay import load_session_replay, ReplayCursor
from honda_analyzer.analysis.ecu_census import passive_ecu_census
from honda_analyzer.analysis.response_inventory import diagnostic_response_inventory
from honda_analyzer.analysis.payload_workspace import TimedPayload, differential
from honda_analyzer.analysis.standard_obd import supported_pids_from_bitmap_response, state_pid_choices, decode_hybrid_ev_9a, decode_standard_pid
from honda_analyzer.analysis.auto_drive_state import AutoDriveStateTracker
from honda_analyzer.analysis.did_discovery import AsyncDidDiscovery, DidProbeOutcome, classify_uds_22_text
from honda_analyzer.analysis.did_drive import rank_did_fields
from honda_analyzer.analysis.did_scan_timing import profile_for_rate, prioritized_scan_ranges
from honda_analyzer import __version__
from honda_analyzer.build_info import BUILD_ID, SOURCE_HASH


def _storage_replay_self_test():
    try:
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'preflight.sqlite3'; db=SessionDB(path); now=datetime.now(timezone.utc).isoformat(); sid=db.create_session(now,tool_version='preflight')
            writer=AsyncSessionWriter(path,batch_size=8,flush_interval_s=.01)
            writer.append_raw(sid,now,'BLE','preflight',b'abc')
            writer.append_command(sid,now,'010D',b'410D2A\r>',1.0,True)
            writer.add_event(sid,now,'STOP','preflight')
            writer.flush()
            items=load_session_replay(db,sid); cursor=ReplayCursor(items); cursor.consume_until(cursor.duration_s)
            ok=(db.conn.execute('select count(*) from raw_capture where session_id=?',(sid,)).fetchone()[0]==1 and cursor.latest_values.get('Vehicle Speed')==42 and len(cursor.events_until())==1)
            writer.close(); db.conn.close()
            return ok, '非同期保存 → flush → オフライン再生の再構成'
    except Exception as e:
        return False, f'{type(e).__name__}: {e}'


def _ecu_census_self_test():
    rows=[
        ('2026-09-24T00:00:00+00:00','010C',b'18DAF1EF04410C0000\r18DAF10E04410C0000\r18DAF10104410C0000\r18DAF10204410C0000\r18DAF10604410C0000\r>',10.0,1),
        ('2026-09-24T00:00:01+00:00','019A',b'18DAF1011008419A07003EA4\r18DAF10121001C5555555555\r>',10.0,1),
        ('2026-09-24T00:00:02+00:00','222012',b'18DAF101102762201270000F\r18DAF1012100002805AA0000\r18DAF1012200000000000000\r>',10.0,1),
    ]
    try:
        c=passive_ecu_census(rows)
        ids={x.response_can_id for x in c.entries}
        ok=c.responder_count==5 and ids=={'18DAF1EF','18DAF10E','18DAF101','18DAF102','18DAF106'}
        return ok,f'実車形式のmulti-frameを含む応答から {c.responder_count} ECU候補を再構成'
    except Exception as e:
        return False,f'{type(e).__name__}: {e}'


def _analysis_self_test():
    try:
        rows=[('t','010C',b'18DAF1EF04410C1000\r18DAF10E04410C1004\r18DAF10104410C1008\r18DAF10204410C100C\r18DAF10604410C1010\r>',1.0,1)]
        inv=diagnostic_response_inventory(rows)
        a=[TimedPayload(1,'t',bytes([10,100])),TimedPayload(2,'t',bytes([11,101])),TimedPayload(3,'t',bytes([12,102]))]
        b=[TimedPayload(4,'t',bytes([20,100])),TimedPayload(5,'t',bytes([21,103])),TimedPayload(6,'t',bytes([22,106]))]
        d=differential(a,b)
        ok=len(inv)==5 and d[0].a_median==11 and d[0].b_median==21 and d[0].distribution_distance==1.0
        return ok,'5応答IDの保持 + A/B Byte統計比較'
    except Exception as e:
        return False,f'{type(e).__name__}: {e}'


def _auto_drive_capture_self_test():
    try:
        # Bitmap contains 04/0C/0D/11/20; validate discovery plus state labelling.
        text='18DAF10106410018180001\r>'
        supported=supported_pids_from_bitmap_response(text,0x00)
        choices=state_pid_choices(supported)
        tr=AutoDriveStateTracker()
        tr.update('speed',0,0); tr.update('rpm',0,0)
        stop=tr.classify(.1).label
        tr.update('speed',30,1); tr.update('rpm',0,1); tr.update('pedal',20,1)
        ev=tr.classify(1).label
        hev=decode_hybrid_ev_9a('18DAF1011008419A07003B93\r18DAF1012103FA5555555555\r>')
        soc=decode_standard_pid(0x5B,'18DAF10103415B81\r>')
        tr.update('speed',27,2); tr.update('rpm',0,2)
        if hev is not None and hev.power_kw is not None: tr.update('hv_power',-10,2)
        regen=tr.classify(2).label
        ok=(0x0C in supported and 0x0D in supported and stop=='停止' and 'EV走行候補' in ev and
            hev is not None and hev.voltage_v is not None and hev.current_a is not None and soc is not None and '回生' in regen)
        return ok,f'対応PID検出 {len(supported)}件 + SOC/PID9A decode + 自動状態 {stop} → {ev} → {regen}'
    except Exception as e:
        return False,f'{type(e).__name__}: {e}'


async def _did_pipeline_self_test():
    try:
        with tempfile.TemporaryDirectory() as td:
            path=Path(td)/'did.sqlite3'; db=SessionDB(path); sid=db.create_session(datetime.now(timezone.utc).isoformat(),tool_version='preflight')
            async def speed(): return 0.0
            async def probe(ecu,did):
                if did in (0x1001,0x1003):
                    return DidProbeOutcome(ecu,did,'positive',1.0,payload=bytes([did & 0xff]),response_can_id=f'18DAF1{ecu}')
                return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id=f'18DAF1{ecu}')
            def persist(o): db.save_scan_result(sid,o.ecu,o.did,o.status,datetime.now(timezone.utc).isoformat(),o.latency_ms,o.nrc,o.payload,o.response_can_id)
            engine=AsyncDidDiscovery(probe,speed,persist,sleep=lambda _: asyncio.sleep(0))
            await engine.run(['01'],0x1000,0x1003,rate_hz=1000,speed_check_interval_s=10)
            inv=db.positive_did_inventory(['01'])
            db.save_did_drive_plan(sid,inv,datetime.now(timezone.utc).isoformat())
            base=datetime.now(timezone.utc)
            speed_ref=[]; rpm_ref=[]; power_ref=[]; current_ref=[]; soc_ref=[]
            for i in range(12):
                ts=(base.replace(microsecond=0)+__import__('datetime').timedelta(seconds=i)).isoformat(); epoch=datetime.fromisoformat(ts).timestamp(); sp=float(i*3)
                db.append_did_drive_sample(sid,ts,'01',0x1001,'18DAF101',int(sp*100).to_bytes(2,'big'),1.0,True)
                speed_ref.append((epoch,sp)); rpm_ref.append((epoch,0.0)); power_ref.append((epoch,sp)); current_ref.append((epoch,sp)); soc_ref.append((epoch,50.0))
            rows=db.did_drive_rows(sid)
            ranks=rank_did_fields(rows,speed=speed_ref,engine_rpm=rpm_ref,hv_power=power_ref,hv_current=current_ref,soc=soc_ref,top_n=10)
            fast=profile_for_rate(10.0); ranges=prioritized_scan_ranges(0,0xFFFF)
            ok=(len(inv)==2 and len(db.did_drive_plan(sid))==2 and bool(ranks) and
                max((x.corr_speed_ev or 0) for x in ranks)>0.99 and
                fast.setup_commands==('ATAT2','ATST0F') and ranges[0]==(0x2000,0x20FF))
            db.conn.close()
            return ok,f'Positive DID {len(inv)}件 → 走行plan固定 → Coverage/相関解析 + 10 req/s高速profile + 2000帯先行'
    except Exception as e:
        return False,f'{type(e).__name__}: {e}'


def _long_did_recovery_self_test():
    try:
        partial=(
            '18DAF10110F6622019FFFFFF\r'
            '18DAF10121FFFFFFFFFFFFFF\r'
            '18DAF10122FFFFFFFFFFFFFF\r'
            '18DAF10123FF000000000000\r'
            'BUFFER FULL\r\r>'
        )
        a=classify_uds_22_text(partial,'01',0x2019,120.0)
        compact='00A\r0:622019010203\r1:04050607\r\r>'
        b=classify_uds_22_text(compact,'01',0x2019,80.0)
        ok=(a.status=='positive_partial' and len(a.payload)>0 and b.status=='positive' and b.payload==bytes.fromhex('01020304050607'))
        return ok,'BUFFER FULL partial-positive保持 + ATH0/CAF1形式の完全応答再構成'
    except Exception as e:
        return False,f'{type(e).__name__}: {e}'


async def _run():
    print('Honda e:HEV Analyzer — 実車前チェック')
    print(f'Version: {__version__}  Build: {BUILD_ID}  Source: {SOURCE_HASH[:12]}')
    print(f'Python: {sys.version.split()[0]}  arch={platform.machine()}  macOS={platform.mac_ver()[0] or "not-macOS"}')
    required=('bleak','PySide6','pyqtgraph','numpy')
    missing=[x for x in required if find_spec(x) is None]
    print('デスクトップ依存関係:', 'OK' if not missing else '不足: '+', '.join(missing))
    t=Elm327SimulatorTransport(ElmSimulatorProfile(fragment_sizes=(1,2,3,5),response_delay_ms=0))
    r=await run_vehicle_readiness(t)
    print(f'シミュレータ準備テスト: {r.overall} ({r.metadata.get("pass_count",0)} PASS, {r.metadata.get("warn_count",0)} WARN, {r.metadata.get("fail_count",0)} FAIL)')
    for c in r.checks:
        print(f'  {c.status:4} {c.name}: {c.detail[:100]}')
    storage_ok,storage_detail=_storage_replay_self_test(); print('保存/再生セルフテスト:', 'PASS' if storage_ok else 'FAIL', storage_detail)
    ecu_ok,ecu_detail=_ecu_census_self_test(); print('ECU確認セルフテスト:', 'PASS' if ecu_ok else 'FAIL', ecu_detail)
    analysis_ok,analysis_detail=_analysis_self_test(); print('走行解析セルフテスト:', 'PASS' if analysis_ok else 'FAIL', analysis_detail)
    auto_ok,auto_detail=_auto_drive_capture_self_test(); print('自動走行判定/標準PIDセルフテスト:', 'PASS' if auto_ok else 'FAIL', auto_detail)
    did_ok,did_detail=await _did_pipeline_self_test(); print('DID探索→走行巡回セルフテスト:', 'PASS' if did_ok else 'FAIL', did_detail)
    long_ok,long_detail=_long_did_recovery_self_test(); print('長大DID応答セルフテスト:', 'PASS' if long_ok else 'FAIL', long_detail)
    if missing or r.overall!='PASS' or not storage_ok or not ecu_ok or not analysis_ok or not auto_ok or not did_ok or not long_ok:return 1
    print('\n実車前ソフトウェアチェック: PASS')
    print('次：車を安全な場所に停車・Pレンジ → KW905接続 → アプリの「1. 接続・準備」から進めてください。')
    print('DID範囲探索は自動では開始しません。「3. ECU確認」で停車条件を確認して手動開始します。')
    return 0


def main():
    raise SystemExit(asyncio.run(_run()))
if __name__=='__main__':main()
