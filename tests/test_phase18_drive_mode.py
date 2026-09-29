from honda_analyzer.gui.drive_mode import MARKERS, SHORTCUTS, communication_alert

def test_drive_markers_and_shortcuts_are_stable():
    assert MARKERS == ("STOP","EV","ENGINE ON","ACCEL","CRUISE","REGEN","CUSTOM")
    assert SHORTCUTS["1"] == "STOP" and SHORTCUTS["6"] == "REGEN"

def test_drive_alert_is_communication_only_and_deterministic():
    assert communication_alert("GOOD",0,0,120).severity == "OK"
    assert communication_alert("FAIR",0.01,0.01,300).severity == "WARN"
    a=communication_alert("GOOD",0.11,0,100)
    assert a.severity == "ALERT" and "Communication" in a.message
    assert communication_alert("NO DATA",0,0,None).severity == "INFO"
