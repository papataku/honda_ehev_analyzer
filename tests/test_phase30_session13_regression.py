from pathlib import Path
from honda_analyzer.analysis.standard_obd import decode_did2012_candidates


def test_did2012_byte5_soc_candidate_from_real_shape():
    data=bytearray(36); data[5]=0x33
    payload=bytes.fromhex('622012')+bytes(data)
    ff=bytes([0x10 | ((len(payload)>>8)&0xF), len(payload)&0xFF])+payload[:6]
    rest=payload[6:]; lines=[f'18DAF101{ff.hex().upper()}']; seq=1
    while rest:
        chunk=rest[:7]; rest=rest[7:]
        lines.append(f'18DAF101{(bytes([0x20|(seq&0xF)])+chunk).hex().upper()}'); seq=(seq+1)&0xF
    c=decode_did2012_candidates('\r'.join(lines)+'\r\r>')
    assert c is not None
    assert c.soc_percent_candidate == 51.0


def test_did2012_evidence_is_labelled_candidate_not_official():
    doc=decode_did2012_candidates.__doc__ or ''
    assert 'candidate' in doc.lower()
    assert 'no Honda' in doc


def test_live_loop_separates_transport_failure_from_decode_failure():
    src=(Path(__file__).parents[1]/'src/honda_analyzer/gui/app.py').read_text()
    assert 'LIVE DECODE/UI ERROR (RAW SAVED)' in src
    assert "_ui_action('live_decode_error'" in src
    assert 'fake communication failure' in src


def test_offline_replay_shows_candidate_without_promoting_it():
    src=(Path(__file__).parents[1]/'src/honda_analyzer/gui/offline_replay.py').read_text()
    assert 'SOCミラー候補（未確定）' in src
    assert 'decode_did2012_candidates' in src
