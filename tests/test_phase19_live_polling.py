from honda_analyzer.analysis.live_polling import DEFAULT_POLLS,DueScheduler,decode_poll

def spec(cmd): return next(s for s in DEFAULT_POLLS if s.command==cmd)

def test_known_decoders_with_headers():
    assert decode_poll(spec('010C'),'18DAF110 04 41 0C 1F 40\r>') == 2000
    assert decode_poll(spec('010D'),'18DAF110 03 41 0D 50\r>') == 80
    assert decode_poll(spec('0105'),'41 05 64\r>') == 60
    assert decode_poll(spec('019A'),'41 9A 01 02 03\r>') == '01 02 03'
    assert decode_poll(spec('222012'),'18DAF116 62 20 12 AA BB CC\r>') == 'AA BB CC'

def test_unknown_or_no_data_is_not_invented():
    assert decode_poll(spec('222012'),'NO DATA\r>') is None
    assert decode_poll(spec('019A'),'7F 22 31\r>') is None

def test_due_scheduler_never_builds_catchup_burst():
    sch=DueScheduler((spec('010C'),),now=0.0)
    s=sch.due(10.0); assert s.command=='010C'
    sch.mark(s,10.0)
    assert sch.due(10.01) is None
    assert sch.due(10.49) is None
    assert sch.due(10.50).command=='010C'


def test_poll_headers_are_explicit_and_separate():
    assert spec('010C').header == '18DB33F1'
    assert spec('019A').header == '18DB33F1'
    assert spec('222012').header == '18DBEFF1'


def test_multiline_raw_payload_is_joined_without_guessing_fields():
    text='18DAF110419A102030405060\r18DAF110419A708090A0B0C0\r>'
    assert decode_poll(spec('019A'),text) == '10 20 30 40 50 60 70 80 90 A0 B0 C0'
