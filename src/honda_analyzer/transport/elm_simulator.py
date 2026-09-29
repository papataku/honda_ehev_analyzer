from __future__ import annotations
import asyncio, random
from dataclasses import dataclass, field
from .base import Transport, RawChunk

@dataclass
class ElmSimulatorProfile:
    name: str = 'KW905-SIM'
    fragment_sizes: tuple[int,...] = (7, 13, 5, 64)
    response_delay_ms: float = 8.0
    rpm: int = 1250
    speed_kph: int = 0
    coolant_c: int = 82
    voltage_v: float = 310.0
    current_a: float = -12.5
    soc_pct: float = 50.0
    prompt: bytes = b'>'

class Elm327SimulatorTransport(Transport):
    """Deterministic-enough ELM/KW905 simulator for Mac-only pre-vehicle testing.

    It deliberately fragments replies across transport chunks. PID 9A follows the
    standard J1979 field layout with synthetic values; DID 2012 remains synthetic
    unknown test data and never defines Honda vehicle semantics.
    """
    def __init__(self, profile: ElmSimulatorProfile|None=None, seed: int=1):
        self.profile=profile or ElmSimulatorProfile(); self.rx=asyncio.Queue(); self.tx=[]
        self.connected=False; self.echo=True; self.headers=False; self.spaces=True; self.current_priority='18'; self.current_header=None; self._rng=random.Random(seed)
    async def connect(self): self.connected=True
    async def disconnect(self): self.connected=False
    async def recv(self): return await self.rx.get()
    async def write(self,data:bytes):
        if not self.connected: raise ConnectionError('simulator disconnected')
        self.tx.append(bytes(data)); cmd=data.decode('ascii','replace').strip().upper()
        await asyncio.sleep(self.profile.response_delay_ms/1000)
        response=self._response(cmd)
        if self.echo: response=(cmd+'\r').encode()+response
        response += self.profile.prompt
        sizes=self.profile.fragment_sizes or (len(response),)
        pos=0; i=0
        while pos<len(response):
            n=sizes[i%len(sizes)]; chunk=response[pos:pos+n]; pos+=n; i+=1
            await self.rx.put(RawChunk.now(chunk,'elm-simulator'))
    def _line(self,s): return (s+'\r').encode()
    def _response(self,cmd):
        p=self.profile
        if cmd=='ATZ':
            self.echo=True; self.headers=False; self.spaces=True; self.current_priority='18'; self.current_header=None
            return self._line('ELM327 v1.5')
        if cmd=='ATE0': self.echo=False; return self._line('OK')
        if cmd=='ATS0': self.spaces=False; return self._line('OK')
        if cmd in {'ATL0','ATAL','ATCAF1','ATCFC1','ATSP7'}: return self._line('OK')
        if cmd=='ATH1': self.headers=True; return self._line('OK')
        if cmd=='ATI': return self._line('ELM327 v1.5')
        if cmd=='ATDP': return self._line('ISO 15765-4 (CAN 29/500)')
        if cmd=='ATDPN': return self._line('A7')
        if cmd=='AT@1': return self._line(p.name)
        if cmd.startswith('ATCP'):
            value=cmd[4:]
            if len(value)==2 and all(c in '0123456789ABCDEF' for c in value):
                self.current_priority=value; return self._line('OK')
            return self._line('?')
        if cmd.startswith('ATSH'):
            value=cmd[4:]
            # Classic ELM327 SH is three bytes for a 29-bit CAN ID.  This
            # intentionally rejects 8-digit SH to match the user's KW905 v1.5.
            if len(value)==6 and all(c in '0123456789ABCDEF' for c in value):
                self.current_header=self.current_priority+value
                return self._line('OK')
            return self._line('?')
        if cmd=='0100': return self._obd('41 00 BE 3E B8 13')
        if cmd=='010C':
            raw=int(p.rpm*4); return self._obd('41 0C %02X %02X'%((raw>>8)&255,raw&255))
        if cmd=='010D': return self._obd('41 0D %02X'%(p.speed_kph&255))
        if cmd=='0105': return self._obd('41 05 %02X'%((p.coolant_c+40)&255))
        if cmd=='015B':
            raw=max(0,min(255,round(p.soc_pct*255.0/100.0)))
            return self._obd('41 5B %02X'%raw)
        if cmd=='019A':
            # Standard J1979 PID 9A layout, but synthetic values.
            vraw=max(0,min(0xFFFF,round(p.voltage_v/0.015625)))
            iraw=int(round(p.current_a/0.1)) & 0xFFFF
            # Total payload length after ISO-TP PCI is 8 bytes: 41 9A + A..F.
            ff='10 08 41 9A 07 00 %02X %02X'%((vraw>>8)&255,vraw&255)
            cf='21 %02X %02X 55 55 55 55 55'%((iraw>>8)&255,iraw&255)
            return self._obd(ff+'\r'+cf)
        if cmd in {'222012','22 2012'}:
            # Synthetic UDS positive response. No RP8 offset semantics are implied.
            payload='62 20 12 ' + ' '.join(f'{(i*7)&255:02X}' for i in range(48))
            header='18DAF116'
            # If the caller selected standard physical request 18DAxxF1, mirror xx
            # back in the standard response form 18DAF1xx. This tests addressing only.
            if self.current_header and len(self.current_header)==8 and self.current_header.startswith('18DA') and self.current_header.endswith('F1'):
                header='18DAF1'+self.current_header[4:6]
            return self._obd(payload, header=header)
        return self._line('NO DATA')
    def _obd(self,text,header='18DAF110'):
        lines=[]
        for line in text.split('\r'):
            rendered=(header+' '+line) if self.headers else line
            if not self.spaces: rendered=rendered.replace(' ','')
            lines.append(self._line(rendered))
        return b''.join(lines)
    def set_vehicle_state(self, *, rpm=None, speed_kph=None, coolant_c=None, voltage_v=None, current_a=None, soc_pct=None):
        for k,v in locals().copy().items():
            if k not in {'self'} and v is not None: setattr(self.profile,k,v)

@dataclass
class LinkFaultPlan:
    """Command-indexed link faults for integration testing; never vehicle semantics."""
    disconnect_on: set[int] = field(default_factory=set)
    timeout_on: set[int] = field(default_factory=set)
    duplicate_on: set[int] = field(default_factory=set)
    merge_fragments_on: set[int] = field(default_factory=set)

class ResilientElmSimulatorTransport(Elm327SimulatorTransport):
    """Simulator variant for reconnect/timeout/duplicate/merge integration tests."""
    def __init__(self, profile=None, seed=1, fault_plan=None):
        super().__init__(profile, seed); self.fault_plan=fault_plan or LinkFaultPlan(); self.command_index=0
    async def write(self,data:bytes):
        idx=self.command_index; self.command_index += 1
        if idx in self.fault_plan.disconnect_on:
            self.connected=False; raise ConnectionError(f'simulated disconnect at command {idx}')
        if not self.connected: raise ConnectionError('simulator disconnected')
        self.tx.append(bytes(data)); cmd=data.decode('ascii','replace').strip().upper()
        await asyncio.sleep(self.profile.response_delay_ms/1000)
        if idx in self.fault_plan.timeout_on: return
        response=self._response(cmd)
        if self.echo: response=(cmd+'\r').encode()+response
        response += self.profile.prompt
        sizes=self.profile.fragment_sizes or (len(response),)
        chunks=[]; pos=0; i=0
        while pos<len(response):
            n=sizes[i%len(sizes)]; chunks.append(response[pos:pos+n]); pos+=n; i+=1
        if idx in self.fault_plan.merge_fragments_on: chunks=[b''.join(chunks)]
        if idx in self.fault_plan.duplicate_on and chunks: chunks.insert(1,chunks[0])
        for chunk in chunks: await self.rx.put(RawChunk.now(chunk,'elm-simulator-fault'))
