import pytest
from honda_analyzer.protocol.elm327 import ElmPromptFramer
from honda_analyzer.protocol.obd import rpm,coolant_c
from honda_analyzer.protocol.uds import parse_22_response,safe_scan_request
from honda_analyzer.analysis.formula import evaluate
from honda_analyzer.analysis.fields import expand_fields

def test_elm_fragment_merge():
    f=ElmPromptFramer(); assert f.feed(b'41 0C 1A') == []
    r=f.feed(b' F8>OK>'); assert len(r)==2; assert r[0].raw.endswith(b'>'); assert r[1].text=='OK>'
def test_obd(): assert rpm(0x1A,0xF8)==1726; assert coolant_c(90)==50
def test_uds():
    r=parse_22_response(bytes.fromhex('6220120102')); assert r.positive and r.did==0x2012 and r.payload==b'\x01\x02'
    n=parse_22_response(bytes.fromhex('7F2231')); assert not n.positive and n.nrc==0x31
    assert safe_scan_request(0x203f)==bytes.fromhex('22203f')
def test_formula():
    assert evaluate('(raw - 32768) / 4',32772)==1
    with pytest.raises(ValueError): evaluate('__import__("os")',1)
def test_fields(): assert any(x[1]=='s16be' for x in expand_fields(b'\xff\xfe'))
