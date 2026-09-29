from __future__ import annotations
from dataclasses import dataclass

@dataclass(frozen=True)
class Thresholds:
    stopped_kph: float=1.0; engine_on_rpm: float=100.0; accel_kph_s: float=1.2; regen_kw: float=1.0; power_kw: float=-1.0

def classify(samples, thresholds=Thresholds()):
    labels=[]
    for i,s in enumerate(samples):
        prev=samples[i-1] if i else s
        dt=max(1e-9,s.t-prev.t); accel=(s.speed-prev.speed)/dt
        states=[]
        states.append('STOP' if s.speed<thresholds.stopped_kph else 'MOVING')
        states.append('ENGINE ON' if s.engine_rpm>=thresholds.engine_on_rpm else 'ENGINE OFF')
        if s.hv_power>=thresholds.regen_kw and s.speed>=thresholds.stopped_kph: states.append('REGEN')
        elif accel>=thresholds.accel_kph_s: states.append('ACCEL')
        elif accel<=-thresholds.accel_kph_s: states.append('DECEL')
        else: states.append('CRUISE')
        if s.hv_power<=thresholds.power_kw: states.append('POWER')
        labels.append(tuple(states))
    return labels
