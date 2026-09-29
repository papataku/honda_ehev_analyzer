import asyncio
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport, ElmSimulatorProfile
from honda_analyzer.protocol.elm_session import ElmSession, initialize

def run(c): return asyncio.run(c)

def test_simulator_initialization_and_fragmented_prompt():
    async def case():
        t=Elm327SimulatorTransport(ElmSimulatorProfile(fragment_sizes=(1,2,3)))
        await t.connect(); s=ElmSession(t); results=await initialize(s)
        assert len(results)==13
        assert any(r.command=='ATI' and 'ELM327' in r.text for r in results)
        assert any(r.command=='ATDPN' and 'A7' in r.text for r in results)
    run(case())

def test_known_obd_and_synthetic_uds():
    async def case():
        t=Elm327SimulatorTransport(); await t.connect(); s=ElmSession(t)
        await s.command('ATE0'); r=await s.command('010C'); assert '41 0C' in r.text
        await s.command('ATH1'); u=await s.command('222012'); assert '18DAF116' in u.text and '62 20 12' in u.text
    run(case())

def test_state_change_for_scenario():
    async def case():
        t=Elm327SimulatorTransport(); t.set_vehicle_state(rpm=0,speed_kph=80); await t.connect(); s=ElmSession(t); await s.command('ATE0')
        r=await s.command('010D'); assert '50' in r.text
        r=await s.command('010C'); assert '00 00' in r.text
    run(case())
