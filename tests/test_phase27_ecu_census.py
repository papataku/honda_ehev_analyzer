from honda_analyzer.analysis.ecu_census import (
    passive_ecu_census, physical_request_id_for_ecu, expected_response_id_for_ecu,
    SAFE_CENSUS_COMMANDS,
)


def row(ts, cmd, text, success=True):
    return (ts, cmd, text.encode('ascii'), 10.0, success)


def test_passive_census_counts_distinct_ecu_responders_and_not_isotp_frames():
    rows = [
        row('2026-09-24T00:00:00+00:00','010C',
            '18DAF1EF04410C0000\r18DAF10E04410C0000\r18DAF10104410C0000\r18DAF10204410C0000\r18DAF10604410C0000\r>'),
        row('2026-09-24T00:00:01+00:00','019A',
            '18DAF1011008419A07003EA4\r18DAF10121001C5555555555\r>'),
        row('2026-09-24T00:00:02+00:00','222012',
            '18DAF101102762201270000F\r18DAF1012100002805AA0000\r18DAF1012200000000000000\r>'),
    ]
    c = passive_ecu_census(rows)
    assert c.responder_count == 5
    ids = {x.response_can_id for x in c.entries}
    assert ids == {'18DAF1EF','18DAF10E','18DAF101','18DAF102','18DAF106'}
    one = next(x for x in c.entries if x.ecu == '01')
    assert one.response_count == 3  # 010C, 019A, 222012; not every CF frame
    assert {'010C','019A','222012'} <= set(one.commands)
    assert c.matrix[('01','019A')] == 1  # multi-frame ISO-TP response counts as one command response


def test_failed_commands_are_not_counted_and_safe_filter_works():
    rows = [
        row('2026-09-24T00:00:00+00:00','ATSHDB33F1','18DAF10103410D00\r>'),
        row('2026-09-24T00:00:01+00:00','010D','18DAF10103410D00\r>',False),
        row('2026-09-24T00:00:02+00:00','0105','18DAF1010341054F\r>',True),
    ]
    c = passive_ecu_census(rows, safe_only=True)
    assert c.responder_count == 1
    assert c.entries[0].commands == ('0105',)
    assert '0105' in SAFE_CENSUS_COMMANDS


def test_physical_request_mapping_is_explicit_and_reversible_for_common_id():
    assert physical_request_id_for_ecu('01') == '18DA01F1'
    assert physical_request_id_for_ecu('EF') == '18DAEFF1'
    assert expected_response_id_for_ecu('01') == '18DAF101'
