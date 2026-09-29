import asyncio

from honda_analyzer.protocol.can_header import elm327_header_commands, split_29bit_header
from honda_analyzer.protocol.elm_session import ElmSession
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport, ElmSimulatorProfile
from honda_analyzer.analysis.readiness import run_vehicle_readiness


def test_classic_elm_29bit_header_command_split():
    assert split_29bit_header('18DB33F1') == ('18','DB33F1')
    assert elm327_header_commands('18DB33F1') == ('ATCP18','ATSHDB33F1')
    assert elm327_header_commands('18DBEFF1','18') == ('ATSHDBEFF1',)


def test_simulator_rejects_old_8_digit_atsh_like_real_kw905():
    async def run():
        t=Elm327SimulatorTransport(ElmSimulatorProfile(response_delay_ms=0)); await t.connect(); s=ElmSession(t)
        bad=await s.command('ATSH18DB33F1')
        cp=await s.command('ATCP18'); sh=await s.command('ATSHDB33F1')
        return bad,cp,sh,t.current_header
    bad,cp,sh,h=asyncio.run(run())
    assert bad.success is False
    assert cp.success and sh.success
    assert h=='18DB33F1'


def test_readiness_uses_clone_compatible_header_sequence():
    t=Elm327SimulatorTransport(ElmSimulatorProfile(response_delay_ms=0))
    r=asyncio.run(run_vehicle_readiness(t))
    assert r.overall=='PASS'
    commands=[c.command for c in r.checks if c.command]
    assert 'ATCP18' in commands
    assert 'ATSHDB33F1' in commands
    assert 'ATSHDBEFF1' in commands
    assert 'ATSH18DB33F1' not in commands
