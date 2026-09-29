from dataclasses import dataclass
from honda_analyzer.analysis.field_correlation import field_series,align_nearest,best_lag,analyze_field

@dataclass
class P:
 elapsed_s:float
 payload:bytes

def test_field_series_and_async_alignment():
 s=[P(i,bytes([0,int(i*10)])) for i in range(1,8)]
 fs=field_series(s,1,'u8'); ref=[(i+.2,i*10) for i in range(1,8)]
 _,a,b=align_nearest(fs,ref,.4)
 assert a==b and len(a)==7
 r=analyze_field(s,1,'u8','Vehicle Speed',ref,tolerance_s=.4)
 assert r.samples==7 and r.pearson>.999 and r.spearman>.999

def test_best_lag_finds_delayed_reference():
 cand=[(float(i),float(i*i)) for i in range(8)]
 ref=[(float(i)+1.0,float(i*i)) for i in range(8)]
 lag=best_lag(cand,ref,max_lag_s=2,step_s=.25,tolerance_s=.1)
 assert lag is not None and abs(lag[0]-1.0)<1e-9 and lag[1]>.999

def test_motor_candidate_is_evidence_not_verification():
 s=[];speed=[];engine=[]
 for i in range(10):
  sp=0 if i<2 else i*10; en=0
  # synthetic field deliberately speed-related; this is test truth, not Honda evidence
  s.append(P(float(i),int(sp*20).to_bytes(2,'big')));speed.append((float(i),sp));engine.append((float(i),en))
 r=analyze_field(s,0,'u16be','Vehicle Speed',speed,speed_series=speed,engine_series=engine,tolerance_s=.01)
 assert r.candidate_score is not None and r.candidate_score>=.7
 assert not hasattr(r,'verified')
