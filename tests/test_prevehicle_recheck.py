import asyncio, time
import pytest
from honda_analyzer.protocol.elm_session import ElmSession,response_success,is_read_only_vehicle_command
from honda_analyzer.protocol.elm_text import find_obd_payload,find_uds_22_payload,isotp_messages
from honda_analyzer.transport.base import Transport,RawChunk
from honda_analyzer.transport.ble import GattCharacteristic,choose_gatt_pair
from honda_analyzer.transport.elm_simulator import Elm327SimulatorTransport,ElmSimulatorProfile
from honda_analyzer.analysis.readiness import run_vehicle_readiness


def test_response_status_rejects_elm_no_data_and_bus_failures():
    assert response_success('41 0C 1F 40\r>')
    for text in ('NO DATA\r>','CAN ERROR\r>','BUS ERROR\r>','STOPPED\r>','?\r>'):
        assert not response_success(text)


def test_safe_terminal_guard_defaults_to_reads():
    assert is_read_only_vehicle_command('ATI')
    assert is_read_only_vehicle_command('01 0C')
    assert is_read_only_vehicle_command('22 2012')
    assert not is_read_only_vehicle_command('2E 2012 00')
    assert not is_read_only_vehicle_command('10 03')


def test_compact_and_isotp_multiframe_decode():
    assert find_obd_payload('18DAF11004410C1F40\r>',1,0x0C)==bytes.fromhex('1F 40')
    text='18DAF116100B622012AABBCC\r18DAF11621DDEEFF0102\r>'
    hit=find_uds_22_payload(text,0x2012)
    assert hit and hit[1]=='18DAF116' and hit[0]==bytes.fromhex('AA BB CC DD EE FF 01 02')


class Trickle(Transport):
    def __init__(self):self.connected=False
    async def connect(self):self.connected=True
    async def disconnect(self):self.connected=False
    async def write(self,data):pass
    async def recv(self):
        await asyncio.sleep(.02)
        return RawChunk.now(b'X','trickle')


def test_command_timeout_is_total_deadline_not_per_chunk():
    async def run():
        t=Trickle(); await t.connect(); s=ElmSession(t); start=time.perf_counter()
        with pytest.raises(asyncio.TimeoutError): await s.command('ATI',timeout=.06)
        return time.perf_counter()-start
    elapsed=asyncio.run(run())
    assert elapsed < .14


def test_gatt_pair_prefers_same_service():
    g=[
      GattCharacteristic('svcA','writeA',('write-without-response',)),
      GattCharacteristic('svcB','notifyB',('notify',)),
      GattCharacteristic('svcA','notifyA',('notify',)),
    ]
    assert choose_gatt_pair(g)==('writeA','notifyA')


class No2012(Elm327SimulatorTransport):
    def _response(self,cmd):
        if cmd in {'222012','22 2012'}: return self._line('NO DATA')
        return super()._response(cmd)


def test_readiness_marks_vehicle_specific_missing_did_warn_not_false_pass():
    r=asyncio.run(run_vehicle_readiness(No2012(ElmSimulatorProfile(response_delay_ms=0))))
    assert r.overall=='WARN'
    did=next(x for x in r.checks if x.command=='222012')
    assert did.status=='WARN'
    assert any(x.name=='Replay parser byte identity' and x.status=='PASS' for x in r.checks)
