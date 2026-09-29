from __future__ import annotations
from dataclasses import dataclass
import math

@dataclass(frozen=True)
class DriveSample:
    t: float; state: str; speed: float; engine_rpm: float; hv_voltage: float; hv_current: float
    motor_rpm: float; generator_rpm: float; coolant: float
    @property
    def hv_power(self): return self.hv_voltage*self.hv_current/1000.0

@dataclass(frozen=True)
class Segment:
    name: str; duration: float; speed0: float; speed1: float; engine0: float; engine1: float; current0: float; current1: float

DEFAULT_CYCLE=(
 Segment('STOP',4,0,0,0,0,-1,-1),
 Segment('EV_LOW',6,0,25,0,0,-5,-18),
 Segment('EV_MEDIUM',6,25,60,0,0,-18,-30),
 Segment('EV_HIGH',6,60,90,0,0,-25,-38),
 Segment('ENGINE_ON',5,90,80,1800,2300,-20,-15),
 Segment('ACCEL',6,80,108,2300,4200,-20,-70),
 Segment('CRUISE',6,108,95,2200,1900,-18,-12),
 Segment('REGEN',7,95,20,0,0,35,65),
 Segment('STOP',4,20,0,0,0,10,0),
)

def generate_drive_cycle(dt=0.1, segments=DEFAULT_CYCLE):
    out=[]; t=0.0
    for seg in segments:
        n=max(1,round(seg.duration/dt))
        for j in range(n):
            f=j/max(1,n-1); lerp=lambda a,b:a+(b-a)*f
            speed=lerp(seg.speed0,seg.speed1); engine=lerp(seg.engine0,seg.engine1); current=lerp(seg.current0,seg.current1)
            # Synthetic candidate only: deliberately not an RP8 formula/gear ratio.
            motor=(speed*73.0) + 20.0*math.sin(t*1.7) if speed>0.5 else 0.0
            gen=(engine*1.42 + 25.0*math.sin(t)) if engine>50 else 0.0
            out.append(DriveSample(round(t,6),seg.name,speed,engine,310+3*math.sin(t/4),current,motor,gen,82+0.03*t))
            t+=dt
    return out
