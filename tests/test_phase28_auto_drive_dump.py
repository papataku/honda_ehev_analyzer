from honda_analyzer.analysis.standard_obd import (
    supported_pids_from_bitmap_response, should_continue_bitmap, decode_standard_pid,
    state_pid_choices, mode01_command,
)
from honda_analyzer.analysis.auto_drive_state import AutoDriveStateTracker
from honda_analyzer.analysis.live_polling import dynamic_state_specs


def test_supported_pid_union_across_multiple_ecus():
    # PID 00 response: ECU1 supports 04,0C,0D,11,20; ECU2 supports 05 and 20.
    text='\n'.join([
        '18DAF10106410018180001',
        '18DAF10206410008000001',
        '>',
    ])
    p=supported_pids_from_bitmap_response(text,0x00)
    assert 0x04 in p and 0x0C in p and 0x0D in p and 0x20 in p
    assert should_continue_bitmap(text,0x00)


def test_standard_pid_decoders():
    assert decode_standard_pid(0x0C,'18DAF10104410C1770\r>') == 1500.0
    assert decode_standard_pid(0x0D,'18DAF10103410D32\r>') == 50
    assert round(decode_standard_pid(0x49,'18DAF10103414980\r>'),1) == 50.2
    assert decode_standard_pid(0x5B,'18DAF10103415B80\r>') is not None


def test_state_pid_fallbacks_and_dynamic_specs():
    s={0x0C,0x0D,0x5A,0x45,0x43,0x61,0x62}
    choices=state_pid_choices(s)
    assert choices['pedal']==0x5A
    assert choices['throttle']==0x45
    assert choices['load']==0x43
    specs=dynamic_state_specs(choices)
    cmds={x.command for x in specs}
    assert cmds == {'015A'}
    assert mode01_command(0x5A)=='015A'


def test_auto_state_no_manual_marker_needed():
    t=AutoDriveStateTracker()
    t.update('speed',0,0.0); t.update('rpm',0,0.0)
    assert t.classify(0.1).label=='停止'
    t.update('speed',20,1.0); t.update('rpm',0,1.0); t.update('pedal',20,1.0)
    r=t.classify(1.0)
    assert 'EV走行候補' in r.label
    t.update('speed',24,2.0); t.update('rpm',1800,2.0); t.update('pedal',35,2.0)
    r=t.classify(2.0)
    assert 'エンジン走行' in r.label and '加速' in r.label
    t.update('speed',20,3.0); t.update('rpm',0,3.0); t.update('pedal',0,3.0)
    r=t.classify(3.0)
    assert '回生候補' in r.label
