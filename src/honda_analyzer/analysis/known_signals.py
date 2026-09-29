from dataclasses import dataclass
from honda_analyzer.protocol.obd import rpm,vehicle_speed,coolant_c
@dataclass(frozen=True)
class KnownSignal: name:str; command:str; unit:str
KNOWN=(KnownSignal('Engine RPM','010C','rpm'),KnownSignal('Vehicle Speed','010D','km/h'),KnownSignal('Coolant','0105','°C'),KnownSignal('HV Battery SOC','015B','%'),KnownSignal('Hybrid/EV PID 9A','019A','raw'),KnownSignal('UDS DID 2012','222012','raw'))
def decode(name,payload):
    if name=='Engine RPM' and len(payload)>=2:return rpm(payload[0],payload[1])
    if name=='Vehicle Speed' and payload:return vehicle_speed(payload[0])
    if name=='Coolant' and payload:return coolant_c(payload[0])
    if name=='HV Battery SOC' and payload:return payload[0]*100.0/255.0
    return payload.hex(' ').upper()
