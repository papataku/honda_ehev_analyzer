from __future__ import annotations

import asyncio
import json
import zipfile
from datetime import datetime, timezone

from honda_analyzer.analysis.did_discovery import AsyncDidDiscovery, DidProbeOutcome, classify_uds_22_text
from honda_analyzer.protocol.elm_text import isotp_messages, isotp_partial_messages
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.storage.async_writer import AsyncSessionWriter
from honda_analyzer.debug_bundle import create_session_debug_bundle


def test_session15_style_buffer_full_is_positive_partial_not_error():
    # Real shape observed in Session 15 DID 0x2019. The FF declares 0x0F6 bytes,
    # but the adapter runs out of host-output buffer before all CFs arrive.
    text=(
        '18DAF10110F6622019FFFFFF\r'
        '18DAF10121FFFFFFFFFFFFFF\r'
        '18DAF10122FFFFFFFFFFFFFF\r'
        '18DAF10123FF000000000000\r'
        '18DAF1012400000003CF03CD\r'
        '18DAF1012503CE03CB03C903\r'
        '18DAF10126CB03CB03CE03CA\r'
        '18DAF1012703CD03C903D003\r'
        '18DAF10128C803CD03CA03CA\r'
        '18DAF1012903CB03ED03D203\r'
        '18DAF1012AED03C803CD03CE\r'
        'BUFFER FULL\r\r>'
    )
    out=classify_uds_22_text(text,'01',0x2019,170.0)
    assert out.status=='positive_partial'
    assert out.response_can_id=='18DAF101'
    assert len(out.payload)>50
    assert 'BUFFER FULL' in out.raw_text


def test_headerless_caf1_multiline_complete_and_partial_are_parsed():
    complete='00A\r0: 62 20 19 01 02 03\r1: 04 05 06 07\r\r>'
    msgs=isotp_messages(complete)
    assert msgs and msgs[0].payload==bytes.fromhex('62201901020304050607')
    out=classify_uds_22_text(complete,'01',0x2019,10)
    assert out.status=='positive' and out.payload==bytes.fromhex('01020304050607')
    # CAN ID is safely inferred because discovery uses a physical request to one ECU.
    assert out.response_can_id=='18DAF101'

    partial='00A\r0:622019010203\rBUFFER FULL\r>'
    frags=isotp_partial_messages(partial)
    assert frags and frags[0].total_length==0x00A
    out=classify_uds_22_text(partial,'01',0x2019,10)
    assert out.status=='positive_partial' and out.payload==bytes.fromhex('010203')


def test_partial_positive_is_terminal_for_resume_and_in_positive_inventory(tmp_path):
    db=SessionDB(tmp_path/'a.db')
    sid=db.create_session(datetime.now(timezone.utc).isoformat())
    db.save_scan_result(sid,'01',0x2019,'positive_partial',datetime.now(timezone.utc).isoformat(),170,None,b'prefix','18DAF101')
    assert 0x2019 in db.completed_dids_global('01',0x2000,0x20FF)
    inv=db.positive_did_inventory(['01'])
    assert len(inv)==1 and inv[0][1]==0x2019 and inv[0][2]==b'prefix'
    db.conn.close()


def test_five_partial_positives_do_not_trigger_infrastructure_abort():
    calls=[]
    async def speed(): return 0.0
    async def probe(ecu,did):
        calls.append(did)
        return DidProbeOutcome(ecu,did,'positive_partial',1.0,payload=b'prefix',response_can_id='18DAF101')
    async def run():
        e=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        return await e.run(['01'],0,9,rate_hz=10000,speed_check_interval_s=99)
    rows=asyncio.run(run())
    assert len(rows)==10 and len(calls)==10
    assert all(x.status=='positive_partial' for x in rows)


def test_drive_sample_partial_flag_migrates_and_exports(tmp_path):
    path=tmp_path/'a.db'; db=SessionDB(path)
    sid=db.create_session(datetime.now(timezone.utc).isoformat(),tool_version='0.3.4')
    db.save_did_drive_plan(sid,[('01',0x2019,b'prefix','18DAF101',sid)],datetime.now(timezone.utc).isoformat())
    writer=AsyncSessionWriter(path,batch_size=2,flush_interval_s=.01)
    try:
        writer.append_did_drive_sample(sid,datetime.now(timezone.utc).isoformat(),'01',0x2019,'18DAF101',b'prefix',180,True,True)
        writer.flush()
        rows=db.did_drive_rows(sid)
        assert rows and rows[0][-1]==1
        cov=db.did_drive_coverage(sid)
        assert cov[0][2]==1 and cov[0][-1]==1
    finally:
        writer.close()
    out=tmp_path/'bundle.zip'; create_session_debug_bundle(out,path,sid,tool_version='0.3.4')
    with zipfile.ZipFile(out) as z:
        samples=[json.loads(x) for x in z.read('did_drive_samples.jsonl').decode().splitlines()]
        assert samples[0]['partial'] is True
    db.conn.close()


def test_detailed_inventory_exposes_full_vs_partial(tmp_path):
    db=SessionDB(tmp_path/'detail.db')
    sid=db.create_session(datetime.now(timezone.utc).isoformat())
    now=datetime.now(timezone.utc).isoformat()
    db.save_scan_result(sid,'01',0x2012,'positive',now,80,None,b'full','18DAF101')
    db.save_scan_result(sid,'01',0x2019,'positive_partial',now,120,None,b'prefix','18DAF101')
    rows=db.positive_did_inventory_detailed(['01'])
    assert [(x[1],x[2]) for x in rows]==[(0x2012,'positive'),(0x2019,'positive_partial')]
    db.conn.close()


def test_phase34_ui_source_has_partial_status_and_coverage_columns():
    from pathlib import Path
    src=(Path(__file__).parents[1]/'src/honda_analyzer/gui/ecu_discovery.py').read_text(encoding='utf-8')
    assert "'取得状態'" in src
    assert "'部分応答数'" in src
    assert '部分（末尾欠落）' in src
