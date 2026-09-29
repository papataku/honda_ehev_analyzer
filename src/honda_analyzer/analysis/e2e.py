from __future__ import annotations
from dataclasses import asdict
from .drive_cycle import generate_drive_cycle
from .state_classifier import classify
from .candidates import motor_rpm_candidate, generator_rpm_candidate
from .correlation import stats, lag_correlation

def run_synthetic_e2e(dt=0.1):
    s=generate_drive_cycle(dt); labels=classify(s)
    speed=[x.speed for x in s]; engine=[x.engine_rpm for x in s]; power=[x.hv_power for x in s]
    motor=[x.motor_rpm for x in s]; gen=[x.generator_rpm for x in s]
    return {
      'samples':len(s),'duration_s':s[-1].t if s else 0,'states':sorted({z for row in labels for z in row}),
      'motor_candidate':asdict(motor_rpm_candidate(motor,speed,engine)),
      'generator_candidate':asdict(generator_rpm_candidate(gen,engine,power)),
      'motor_stats':asdict(stats(motor)), 'motor_speed_best_lag':lag_correlation(motor,speed,round(2/dt)),
      'warning':'Synthetic drive cycle validates the pipeline only; it is not Honda RP8 signal evidence.'
    }
