from honda_analyzer.analysis.drive_cycle import generate_drive_cycle
from honda_analyzer.analysis.state_classifier import classify, Thresholds
from honda_analyzer.analysis.e2e import run_synthetic_e2e

def test_cycle_contains_required_vehicle_states():
    s=generate_drive_cycle(); names={x.state for x in s}
    assert {'STOP','EV_LOW','EV_MEDIUM','EV_HIGH','ENGINE_ON','ACCEL','CRUISE','REGEN'} <= names
    assert any(x.engine_rpm < 50 and x.speed > 60 for x in s)

def test_classifier_finds_engine_off_moving_and_regen():
    s=generate_drive_cycle(); labels=classify(s)
    assert any('MOVING' in x and 'ENGINE OFF' in x for x in labels)
    assert any('REGEN' in x for x in labels)

def test_thresholds_are_recomputable():
    s=generate_drive_cycle(); a=classify(s,Thresholds(engine_on_rpm=100)); b=classify(s,Thresholds(engine_on_rpm=5000))
    assert sum('ENGINE ON' in x for x in a) > sum('ENGINE ON' in x for x in b)

def test_e2e_candidates_are_high_for_synthetic_truth():
    r=run_synthetic_e2e()
    assert r['samples'] > 300
    assert r['motor_candidate']['score'] >= .75
    assert r['generator_candidate']['score'] >= .7
    assert 'not Honda RP8 signal evidence' in r['warning']
