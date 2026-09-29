from __future__ import annotations

import asyncio
import json
import zipfile
from datetime import datetime, timezone, timedelta

from honda_analyzer.analysis.did_discovery import (
    AsyncDidDiscovery, DidProbeOutcome, classify_uds_22_text, estimate_scan_seconds,
)
from honda_analyzer.analysis.did_drive import rank_did_fields
from honda_analyzer.debug_bundle import create_session_debug_bundle
from honda_analyzer.storage.db import SessionDB


def utc(i=0):
    return (datetime(2026, 9, 26, tzinfo=timezone.utc)+timedelta(seconds=i)).isoformat()


def test_classify_uds22_positive_nrc_and_no_data():
    p=classify_uds_22_text('18DAF101056212340102\r>', '01', 0x1234, 12.0)
    assert p.status=='positive' and p.payload==b'\x01\x02' and p.response_can_id=='18DAF101'
    n=classify_uds_22_text('18DAF101037F2231\r>', '01', 0x1235, 13.0)
    assert n.status=='nrc' and n.nrc==0x31
    nd=classify_uds_22_text('NO DATA\r>', '01', 0x1236, 14.0)
    assert nd.status=='no_data'


def test_async_discovery_resume_and_speed_fail_safe():
    seen=[]
    async def speed():
        return 2.0
    async def probe(ecu,did):
        return DidProbeOutcome(ecu,did,'positive',10,payload=b'x',response_can_id='18DAF101')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,seen.append,sleep=lambda _: asyncio.sleep(0))
        return await eng.run(['01'],0,5,rate_hz=1000,completed_by_ecu={'01':{0}},speed_check_interval_s=2.0)
    rows=asyncio.run(run())
    assert rows and rows[0].did==1  # DID 0 was resumed/skipped
    assert rows[0].status=='stopped_speed'
    assert seen[-1].status=='stopped_speed'

def test_scan_estimate_full_range_is_hours():
    # 5 ECUs * 65536 / 2Hz = 163840 sec ~= 45.5h
    sec=estimate_scan_seconds(5,0,0xFFFF,2.0)
    assert 45*3600 < sec < 46*3600


def test_cross_session_resume_and_positive_inventory(tmp_path):
    db=SessionDB(tmp_path/'a.db')
    s1=db.create_session(utc())
    db.save_scan_result(s1,'01',0x1000,'positive',utc(1),10,None,b'aa','18DAF101')
    db.save_scan_result(s1,'01',0x1001,'nrc',utc(2),10,0x31,b'','18DAF101')
    db.save_scan_result(s1,'01',0x1002,'nrc',utc(3),10,0x22,b'','18DAF101')
    db.save_scan_result(s1,'01',0x1003,'timeout',utc(4),1000,None,b'',None)
    done=db.completed_dids_global('01',0x1000,0x1003)
    assert done=={0x1000,0x1001}
    inv=db.positive_did_inventory(['01'])
    assert len(inv)==1 and inv[0][1]==0x1000 and inv[0][2]==b'aa'


def test_drive_plan_coverage_and_debug_bundle(tmp_path):
    db=SessionDB(tmp_path/'a.db'); sid=db.create_session(utc(),tool_version='0.3.1')
    items=[('01',0x1234,b'init','18DAF101',sid),('02',0x2222,b'x','18DAF102',sid)]
    db.save_did_drive_plan(sid,items,utc(1))
    db.append_did_drive_sample(sid,utc(2),'01',0x1234,'18DAF101',b'\x01\x02',12,True)
    db.append_did_drive_sample(sid,utc(3),'01',0x1234,'18DAF101',b'\x01\x03',12,True)
    cov=db.did_drive_coverage(sid)
    assert cov[0][:4]==('01',0x1234,2,2)
    assert cov[1][2]==0
    dest=tmp_path/'bundle.zip'; create_session_debug_bundle(dest,db.path,sid,tool_version='0.3.1')
    with zipfile.ZipFile(dest) as z:
        names=set(z.namelist())
        assert {'did_scan.json','did_drive_plan.json','did_drive_samples.jsonl'} <= names
        plan=json.loads(z.read('did_drive_plan.json'))
        assert len(plan)==2


def test_field_ranking_prioritizes_ev_speed_over_soc_mirror():
    base=datetime(2026,9,26,tzinfo=timezone.utc)
    rows=[]; speed=[]; rpm=[]; power=[]; soc=[]
    for i in range(30):
        t=(base+timedelta(seconds=i)).isoformat(); epoch=(base+timedelta(seconds=i)).timestamp()
        sp=float(i%15)*3.0
        # byte0/1 = synthetic motor-like value proportional to speed; byte2 = slowly changing SOC mirror
        motor=int(sp*100); s=50+i//10
        rows.append((t,'01',0x3456,motor.to_bytes(2,'big')+bytes([s])))
        speed.append((epoch,sp)); rpm.append((epoch,0.0)); power.append((epoch,sp*0.4)); soc.append((epoch,float(s)))
    ranked=rank_did_fields(rows,speed=speed,engine_rpm=rpm,hv_power=power,hv_current=power,soc=soc,top_n=30)
    top=[x for x in ranked if x.did==0x3456][:10]
    assert top
    assert any(x.field=='u16be@0' and (x.corr_speed_ev or 0)>0.99 for x in top)
    soc_fields=[x for x in ranked if x.field=='u8@2']
    assert soc_fields and (soc_fields[0].corr_soc or 0)>0.99
    assert soc_fields[0].motor_score < max(x.motor_score for x in top)


def test_positive_did_round_robin_is_fair_and_deduplicates():
    from honda_analyzer.analysis.did_drive import PositiveDidRoundRobin
    rr=PositiveDidRoundRobin([
        ('01',0x1000,b'',None,1),('02',0x2000,b'',None,1),('01',0x1000,b'',None,2),('01',0x2012,b'',None,1)
    ],exclude_dids={0x2012})
    assert len(rr)==2
    assert [(rr.next()[0],rr.next()[0]) for _ in range(2)]==[('01','02'),('01','02')]



def test_discovery_balances_ecus_in_chunks():
    order=[]
    async def speed():return 0.0
    async def probe(ecu,did):
        order.append((ecu,did)); return DidProbeOutcome(ecu,did,'nrc',1,nrc=0x31,response_can_id=f'18DAF1{ecu}')
    async def run():
        e=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        await e.run(['01','02'],0,5,rate_hz=1000,speed_check_interval_s=99,ecu_chunk_size=2)
    asyncio.run(run())
    assert order[:6]==[('01',0),('01',1),('02',0),('02',1),('01',2),('01',3)]


def test_discovery_stops_after_five_infrastructure_errors():
    calls=[]
    async def speed():return 0.0
    async def probe(ecu,did):
        calls.append(did); return DidProbeOutcome(ecu,did,'error',1,raw_text='header failed')
    async def run():
        e=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        return await e.run(['01'],0,20,rate_hz=1000,speed_check_interval_s=99)
    rows=asyncio.run(run())
    assert len(calls)==5 and len(rows)==5
