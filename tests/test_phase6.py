from honda_analyzer.analysis.fields import expand_fields
from honda_analyzer.analysis.correlation import stats,pearson,spearman,lag_correlation
from honda_analyzer.analysis.change_detection import byte_activity,detect_counter
from honda_analyzer.analysis.candidates import motor_rpm_candidate
from honda_analyzer.analysis.scales import scale_candidates

def test_full_field_expansion():
    f={(o,t):v for o,t,v in expand_fields(bytes.fromhex('FF FE 01 02'))}
    assert f[(0,'u24')]==0xFFFE01 and f[(0,'u32be')]==0xFFFE0102
    assert f[(0,'s16be')]==-2 and f[(0,'u16le')]==0xFEFF

def test_stats_and_correlation():
    s=stats([0,1,2,3]); assert s.unique_count==4 and s.change_rate==1
    assert pearson([1,2,3],[2,4,6])>.999 and spearman([3,1,2],[30,10,20])>.999
    assert lag_correlation([0,1,2,3,4],[0,0,1,2,3],2)[0] in (-1,1)

def test_change_and_counter():
    p=[bytes([0,1]),bytes([0,2]),bytes([0,3]),bytes([0,4])]
    a=byte_activity(p); assert a[0]['constant'] and a[1]['change_rate']==1
    assert detect_counter([1,2,3,4,5])

def test_motor_candidate_is_not_confirmation():
    speed=[0,0,10,20,30,40]; eng=[0]*6; field=[0,0,100,200,300,400]
    c=motor_rpm_candidate(field,speed,eng); assert c.score>.7 and c.evidence

def test_scale_search(): assert any(x['scale']==.25 for x in scale_candidates([0,1000]))
