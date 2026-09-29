from honda_analyzer.analysis.payload_workspace import command_payloads,differential,activity,heatmap_data,expanded_candidates

def rows():
    return [
      ('2026-01-01T00:00:01+00:00','019A',b'419A0010\r>',10,1),
      ('2026-01-01T00:00:02+00:00','019A',b'419A0011\r>',10,1),
      ('2026-01-01T00:00:11+00:00','019A',b'419A2030\r>',10,1),
      ('2026-01-01T00:00:12+00:00','019A',b'419A2031\r>',10,1),
    ]

def test_ranges_diff_heatmap_and_expansion_compact_realistic():
    a=command_payloads(rows(),'019A','2026-01-01T00:00:00+00:00',0,5)
    b=command_payloads(rows(),'019A','2026-01-01T00:00:00+00:00',10,15)
    assert len(a)==2 and len(b)==2
    assert all(len(x.payload)==2 for x in a+b)
    d=differential(a,b); assert d[0].changed and d[0].a==0 and d[0].b==0x20
    act=activity(a+b); assert act[0]>0
    t,o,m=heatmap_data(a+b); assert len(m)==4 and len(m[0])==2
    f=expanded_candidates(a+b,0); assert any(x[1]=='u8' for x in f)
