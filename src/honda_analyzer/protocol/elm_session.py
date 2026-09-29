from __future__ import annotations
import asyncio, time
from dataclasses import dataclass
from .elm327 import ElmPromptFramer

@dataclass(frozen=True)
class CommandResult:
    command:str; raw:bytes; text:str; latency_ms:float; success:bool

# ELM textual outcomes that mean a request did not successfully produce data.
_FAILURE_TEXT=(
    '?','ERROR','UNABLE TO CONNECT','BUS ERROR','CAN ERROR','NO DATA','STOPPED',
    'BUFFER FULL','FB ERROR','LV RESET','ACT ALERT',
)

def response_success(text: str) -> bool:
    u=text.upper()
    return not any(x in u for x in _FAILURE_TEXT)

class ElmSession:
    def __init__(self,transport): self.transport=transport; self.framer=ElmPromptFramer(); self._lock=asyncio.Lock(); self._ready=[]
    async def command(self,command:str,timeout:float=5.0)->CommandResult:
        async with self._lock:
            # Responses are serialized. Any extra complete prompt captured with the
            # previous command is retained rather than discarded, but should not be
            # silently associated with a newly transmitted command.
            if self._ready:
                self._ready.clear()
            t=time.perf_counter(); deadline=t+timeout
            await self.transport.write(command.strip().encode('ascii')+b'\r')
            while True:
                remaining=deadline-time.perf_counter()
                if remaining <= 0:
                    raise asyncio.TimeoutError()
                chunk=await asyncio.wait_for(self.transport.recv(),remaining)
                rs=self.framer.feed(chunk.data)
                if rs:
                    r=rs[0]
                    if len(rs)>1:self._ready.extend(rs[1:])
                    ms=(time.perf_counter()-t)*1000
                    return CommandResult(command,r.raw,r.text,ms,response_success(r.text))

INIT_COMMANDS=('ATZ','ATE0','ATL0','ATS0','ATH1','ATAL','ATCAF1','ATCFC1','ATSP7')
META_COMMANDS=('ATI','ATDP','ATDPN','AT@1')
async def initialize(session):
    out=[]
    for c in INIT_COMMANDS+META_COMMANDS:
        try: out.append(await session.command(c,timeout=8 if c=='ATZ' else 5))
        except Exception as e: out.append(CommandResult(c,b'',f'{type(e).__name__}: {e}',0,False))
    return out

def is_read_only_vehicle_command(command: str) -> bool:
    """Default in-vehicle terminal guard.

    AT adapter configuration is allowed. Vehicle traffic is limited to OBD
    current-data/information requests and UDS ReadDataByIdentifier (0x22).
    Advanced users may explicitly disable the GUI guard when off-vehicle.
    """
    c=''.join(command.upper().split())
    if c.startswith('AT'):
        return True
    if len(c)==4 and c[:2] in {'01','09'}:
        try:int(c,16); return True
        except ValueError:return False
    if len(c)==6 and c.startswith('22'):
        try:int(c,16); return True
        except ValueError:return False
    return False
