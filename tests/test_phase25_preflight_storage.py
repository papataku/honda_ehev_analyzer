from honda_analyzer.preflight import _storage_replay_self_test, _analysis_self_test

def test_preflight_storage_replay_self_test():
    ok,detail=_storage_replay_self_test()
    assert ok, detail


def test_drive_analysis_self_test():
    ok,detail=_analysis_self_test()
    assert ok,detail
