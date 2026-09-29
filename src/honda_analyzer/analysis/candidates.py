from dataclasses import dataclass
from .correlation import pearson

@dataclass(frozen=True)
class Candidate:
    score: float
    evidence: tuple[str,...]
    contradictions: tuple[str,...]


def _ratio(indices, predicate):
    return (sum(1 for i in indices if predicate(i)) / len(indices)) if indices else 0.0


def motor_rpm_candidate(field, speed, engine_rpm):
    ev=[i for i,(s,e) in enumerate(zip(speed,engine_rpm)) if s>5 and abs(e)<50]
    stopped=[i for i,s in enumerate(speed) if s<1]
    evidence=[]; contradictions=[]; score=0.0
    if ev and _ratio(ev, lambda i: abs(field[i])>1)>.7:
        evidence.append('changes/remains nonzero while vehicle moves with engine off'); score+=0.4
    else: contradictions.append('insufficient engine-off moving activity')
    if stopped and _ratio(stopped, lambda i: abs(field[i])<50)>.7:
        evidence.append('near zero while stopped'); score+=0.25
    else: contradictions.append('not near zero while stopped')
    r=pearson(field,speed)
    if r==r and abs(r)>.7: evidence.append(f'strong speed relationship r={r:.3f}'); score+=0.35
    else: contradictions.append('weak speed relationship')
    return Candidate(min(score,1.0),tuple(evidence),tuple(contradictions))


def generator_rpm_candidate(field, engine_rpm, hv_power, engine_on_threshold=100.0):
    """Heuristic only. Generator behaviour is intentionally not equated with drive motor behaviour."""
    on=[i for i,e in enumerate(engine_rpm) if abs(e)>=engine_on_threshold]
    off=[i for i,e in enumerate(engine_rpm) if abs(e)<50]
    evidence=[]; contradictions=[]; score=0.0
    if on and _ratio(on, lambda i: abs(field[i])>1)>.65:
        evidence.append('active during engine-on samples'); score+=0.30
    else: contradictions.append('insufficient engine-on activity')
    if off and _ratio(off, lambda i: abs(field[i])<50)>.55:
        evidence.append('often near zero with engine off'); score+=0.20
    else: contradictions.append('continues strongly with engine off')
    r_engine=pearson(field,engine_rpm)
    if r_engine==r_engine and abs(r_engine)>.55:
        evidence.append(f'engine RPM relationship r={r_engine:.3f}'); score+=0.30
    else: contradictions.append('weak engine RPM relationship')
    r_power=pearson([abs(x) for x in field],[abs(x) for x in hv_power])
    if r_power==r_power and abs(r_power)>.35:
        evidence.append(f'HV power relationship r={r_power:.3f}'); score+=0.20
    else: contradictions.append('weak HV power relationship')
    return Candidate(min(score,1.0),tuple(evidence),tuple(contradictions))


def mechanical_power_kw(torque_nm, rpm):
    """Mechanical power candidate. It must not be treated as equal to HV electrical power."""
    import math
    return torque_nm * rpm * 2.0 * math.pi / 60.0 / 1000.0
