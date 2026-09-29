from __future__ import annotations
from dataclasses import dataclass
import time
from honda_analyzer.protocol.elm_text import find_obd_payload, find_uds_22_payload
from honda_analyzer.protocol.obd import rpm, vehicle_speed, coolant_c
from honda_analyzer.analysis.standard_obd import decode_standard_pid, mode01_command, STANDARD_PIDS

@dataclass(frozen=True)
class PollSpec:
    name: str
    command: str
    interval_s: float
    unit: str
    header: str
    role: str='core'
    pid: int|None=None

# Conservative fixed core. Dynamic standard-PID state probes are added after the
# support bitmap is discovered. Total request rate is intentionally below the
# measured ~120 ms/request KW905 throughput so no command backlog is created.
DEFAULT_POLLS = (
    PollSpec('Engine RPM','010C',0.50,'rpm','18DB33F1','state',0x0C),
    PollSpec('Vehicle Speed','010D',0.50,'km/h','18DB33F1','state',0x0D),
    PollSpec('Coolant','0105',6.0,'°C','18DB33F1','context',0x05),
    PollSpec('HV Battery SOC','015B',5.0,'%','18DB33F1','energy',0x5B),
    PollSpec('Hybrid/EV 019A','019A',0.80,'raw','18DB33F1','energy',0x9A),
    PollSpec('UDS DID 2012','222012',2.5,'raw','18DBEFF1','unknown'),
)

STATE_INTERVALS = {
    'pedal': 1.33,
}


def dynamic_state_specs(choices: dict[str,int|None]) -> tuple[PollSpec,...]:
    out=[]; already={0x0C,0x0D,0x05}
    for role,interval in STATE_INTERVALS.items():
        pid=choices.get(role)
        if pid is None or pid in already:
            continue
        spec=STANDARD_PIDS.get(pid); name=spec.name_ja if spec else f'PID {pid:02X}'
        unit=spec.unit if spec else 'raw'
        out.append(PollSpec(name,mode01_command(pid),interval,unit,'18DB33F1','state',pid)); already.add(pid)
    return tuple(out)


def decode_poll(spec: PollSpec, text: str):
    if spec.pid is not None and spec.pid in STANDARD_PIDS:
        v=decode_standard_pid(spec.pid,text)
        if v is not None:return v
    if spec.command == '010C':
        p=find_obd_payload(text,1,0x0C); return None if not p or len(p)<2 else rpm(p[0],p[1])
    if spec.command == '010D':
        p=find_obd_payload(text,1,0x0D); return None if not p else vehicle_speed(p[0])
    if spec.command == '0105':
        p=find_obd_payload(text,1,0x05); return None if not p else coolant_c(p[0])
    if spec.command == '019A':
        p=find_obd_payload(text,1,0x9A); return None if p is None else p.hex(' ').upper()
    if spec.command == '222012':
        hit=find_uds_22_payload(text,0x2012)
        return None if hit is None else hit[0].hex(' ').upper()
    return None

class DueScheduler:
    """Deterministic due-time selector. One ELM command is issued at a time by the caller."""
    def __init__(self, specs=DEFAULT_POLLS, now: float|None=None):
        self.specs=tuple(specs); base=time.monotonic() if now is None else now
        self.next_due={s.command:base for s in self.specs}
    def due(self, now: float|None=None):
        now=time.monotonic() if now is None else now
        ready=[s for s in self.specs if self.next_due[s.command] <= now]
        return min(ready,key=lambda s:self.next_due[s.command]) if ready else None
    def mark(self,spec:PollSpec,now:float|None=None):
        now=time.monotonic() if now is None else now
        self.next_due[spec.command]=now+spec.interval_s
