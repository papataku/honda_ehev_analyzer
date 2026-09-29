import asyncio
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport, ElmSimulatorProfile
from honda_analyzer.protocol.elm_session import ElmSession, initialize
from honda_analyzer.analysis.safe_ecu_probe import HeaderState, run_safe_census_requests, probe_did_2012_once


def run(c): return asyncio.run(c)


async def _safe_census():
    t=Elm327SimulatorTransport(ElmSimulatorProfile(response_delay_ms=0,fragment_sizes=(2,5,9)))
    await t.connect(); s=ElmSession(t)
    init=await initialize(s); assert all(x.success for x in init[:9])
    seen=[]
    state,rows=await run_safe_census_requests(s,HeaderState(),lambda c,r:seen.append((c,r.success)))
    assert [x[1] for x in rows]==['0100','010C','010D','0105','019A','222012']
    assert all(r.success for *_x,r in rows)
    assert state.header=='18DBEFF1'
    assert ('ATCP18',True) in seen
    await t.disconnect()


def test_safe_census_uses_only_allow_list_and_classic_29bit_header():
    run(_safe_census())


async def _physical_probe():
    t=Elm327SimulatorTransport(ElmSimulatorProfile(response_delay_ms=0,fragment_sizes=(1,3,7)))
    await t.connect(); s=ElmSession(t); await initialize(s)
    state,res=await probe_did_2012_once(s,'01')
    assert res.positive
    assert res.request_id=='18DA01F1'
    assert res.response_can_id=='18DAF101'
    assert state.header=='18DA01F1'
    await t.disconnect()


def test_stationary_probe_addresses_one_ecu_and_reads_one_did():
    run(_physical_probe())
