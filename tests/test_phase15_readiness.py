import asyncio, json
from honda_analyzer.analysis.readiness import run_vehicle_readiness
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport, ElmSimulatorProfile, ResilientElmSimulatorTransport, LinkFaultPlan

def test_readiness_happy_path(tmp_path):
    t=Elm327SimulatorTransport(ElmSimulatorProfile(fragment_sizes=(1,2,3,5),response_delay_ms=0))
    r=asyncio.run(run_vehicle_readiness(t))
    assert r.overall=='PASS'
    assert r.metadata['did_scan_performed'] is False
    assert r.metadata['response_can_id']=='18DAF116'
    assert any(x.name=='Replay parser byte identity' and x.status=='PASS' for x in r.checks)
    p=tmp_path/'readiness.json'; r.write_json(p); d=json.loads(p.read_text()); assert d['overall']=='PASS'
    h=tmp_path/'readiness.html'; r.write_html(h); assert 'Vehicle Readiness' in h.read_text()

def test_readiness_timeout_fails_but_keeps_sequence():
    # Readiness now establishes 9 adapter settings first; index 14 = 010C after ATCP18 + ATSHDB33F1.
    t=ResilientElmSimulatorTransport(ElmSimulatorProfile(response_delay_ms=0),fault_plan=LinkFaultPlan(timeout_on={14}))
    r=asyncio.run(run_vehicle_readiness(t))
    assert r.overall=='FAIL'
    assert any(x.command=='010C' and x.status=='FAIL' for x in r.checks)
    assert any(x.command=='222012' for x in r.checks)
