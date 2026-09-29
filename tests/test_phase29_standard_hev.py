import pytest

from honda_analyzer.analysis.auto_drive_state import AutoDriveStateTracker
from honda_analyzer.analysis.live_polling import DEFAULT_POLLS, decode_poll
from honda_analyzer.analysis.standard_obd import decode_hybrid_ev_9a


def _spec(command):
    return next(s for s in DEFAULT_POLLS if s.command == command)


def test_pid_9a_decodes_voltage_current_and_power_from_isotp():
    # Session-12 shaped response: A=07 support, B=00 state, C/D=3B93, E/F=03FA.
    text = '18DAF1011008419A07003B93\r18DAF1012103FA5555555555\r>'
    d = decode_hybrid_ev_9a(text)
    assert d is not None
    assert d.support_mask == 0x07
    assert d.mode == 0x00
    assert d.voltage_v == pytest.approx(238.296875)
    assert d.current_a == pytest.approx(101.8)
    assert d.power_kw == pytest.approx(24.259, rel=1e-3)


def test_pid_9a_signed_negative_current_means_charge_direction_value_is_preserved():
    # -104.6 A = signed int16 -1046 = 0xFBEA.
    text = '18DAF1011008419A070041C0\r18DAF10121FBEA5555555555\r>'
    d = decode_hybrid_ev_9a(text)
    assert d is not None
    assert d.voltage_v == pytest.approx(263.0)
    assert d.current_a == pytest.approx(-104.6)
    assert d.power_kw == pytest.approx(-27.5098, rel=1e-3)


def test_pid_5b_is_exposed_as_hv_soc_and_decodes_percent():
    spec = _spec('015B')
    assert spec.name == 'HV Battery SOC'
    assert decode_poll(spec, '18DAF10103415B81\r>') == pytest.approx(129 * 100 / 255)


def test_auto_state_confirms_regen_when_decelerating_and_hv_power_is_negative():
    t = AutoDriveStateTracker()
    t.update('speed', 30, 0.0); t.update('rpm', 0, 0.0)
    t.update('speed', 27, 1.0); t.update('rpm', 0, 1.0); t.update('hv_power', -10.0, 1.0)
    r = t.classify(1.0)
    assert '回生' in r.label
    assert r.label.endswith('・回生')
    assert '回生候補' not in r.label
    assert 'HV電力 -10.0 kW' in r.detail


def test_auto_state_does_not_call_positive_power_deceleration_regen():
    t = AutoDriveStateTracker()
    t.update('speed', 30, 0.0); t.update('rpm', 0, 0.0)
    t.update('speed', 27, 1.0); t.update('rpm', 0, 1.0); t.update('hv_power', +2.0, 1.0)
    r = t.classify(1.0)
    assert r.label.endswith('減速')
    assert '回生' not in r.label
