import json
import zipfile
from datetime import datetime, timezone, timedelta

from honda_analyzer.analysis.payload_workspace import TimedPayload, differential, median_payload
from honda_analyzer.analysis.response_inventory import diagnostic_response_inventory
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.debug_bundle import create_session_debug_bundle


def tp(t, payload):
    return TimedPayload(float(t), f'2026-09-26T00:00:{int(t):02d}+00:00', bytes(payload))


def test_payload_ab_uses_per_byte_statistics_not_whole_payload_mode():
    # Every complete payload is unique. Old whole-payload mode could choose an
    # arbitrary first sample. The new result must be the byte-wise distribution.
    a=[tp(1,[10,100]),tp(2,[11,101]),tp(3,[12,102])]
    b=[tp(11,[20,100]),tp(12,[21,103]),tp(13,[22,106])]
    d=differential(a,b)
    assert d[0].a_median == 11 and d[0].b_median == 21
    assert d[0].a_min == 10 and d[0].a_max == 12
    assert d[0].b_min == 20 and d[0].b_max == 22
    assert d[0].distribution_distance == 1.0
    assert median_payload(a) == bytes([11,101])


def test_response_inventory_keeps_all_functional_responders():
    raw=(
        b'18DAF1EF04410C1000\r'
        b'18DAF10E04410C1004\r'
        b'18DAF10104410C1008\r'
        b'18DAF10204410C100C\r'
        b'18DAF10604410C1010\r>'
    )
    rows=[('2026-09-26T00:00:00+00:00','010C',raw,120.0,1)]
    inv=diagnostic_response_inventory(rows)
    assert {x.response_can_id for x in inv} == {'18DAF1EF','18DAF10E','18DAF101','18DAF102','18DAF106'}
    assert all(x.command=='010C' and x.samples==1 for x in inv)


def test_session_evidence_ignores_ui_only_and_bundle_contains_ui_actions(tmp_path):
    db=SessionDB(tmp_path/'s.db')
    sid=db.create_session('2026-09-26T00:00:00+00:00')
    db.add_ui_action(sid,'2026-09-26T00:00:01+00:00','button_pressed','test')
    assert db.session_has_evidence(sid) is False
    db.append_command(sid,'2026-09-26T00:00:02+00:00','010D',b'18DAF10103410D00\r>',100.0,True)
    assert db.session_has_evidence(sid) is True
    out=create_session_debug_bundle(tmp_path/'b.zip',db.path,sid,tool_version='0.2.7')
    with zipfile.ZipFile(out) as z:
        assert 'ui_actions.jsonl' in z.namelist()
        actions=[json.loads(x) for x in z.read('ui_actions.jsonl').decode().splitlines() if x.strip()]
        assert actions[0]['action']=='button_pressed'
        manifest=json.loads(z.read('manifest.json'))
        assert manifest['build_id']
        assert manifest['source_hash']


def test_empty_session_can_be_discarded_without_leaving_ui_only_rows(tmp_path):
    db=SessionDB(tmp_path/'empty.db')
    sid=db.create_session('2026-09-26T00:00:00+00:00')
    db.add_ui_action(sid,'2026-09-26T00:00:01+00:00','session_started','x')
    assert db.discard_session_if_empty(sid) is True
    assert db.session_row(sid) is None
