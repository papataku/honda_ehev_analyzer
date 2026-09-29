from honda_analyzer.analysis.payload_diff import elm_hex_bytes,elm_command_payload,diff_payloads,activity_matrix

def test_elm_hex_extract_and_diff_compact_header_removed():
    a=elm_hex_bytes('18DAF1166220120010\r>')
    b=elm_hex_bytes('18DAF1166220120020\r>')
    assert a==bytes.fromhex('62 20 12 00 10') and b[-1]==0x20
    d=diff_payloads(a,b)
    assert [x.offset for x in d if x.changed]==[4]

def test_command_payload_excludes_service_identifier():
    assert elm_command_payload('18DAF11004419A0010\r>','019A') == bytes.fromhex('00 10')
    assert elm_command_payload('18DAF116622012AABB\r>','222012') == bytes.fromhex('AA BB')

def test_activity_ratio():
    x=[bytes([1,2,3]),bytes([1,4,3]),bytes([1,5,3])]
    r=activity_matrix(x)
    assert r[0]==0 and r[1]==1 and r[2]==0
