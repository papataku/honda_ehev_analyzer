from __future__ import annotations
from dataclasses import dataclass
import math
from statistics import mean, median, pstdev

@dataclass(frozen=True)
class SeriesStats:
    minimum: float; maximum: float; mean: float; median: float; stddev: float
    unique_count: int; zero_ratio: float; change_rate: float

def stats(values):
    v=[float(x) for x in values if x is not None and math.isfinite(float(x))]
    if not v: raise ValueError('empty series')
    changes=sum(a != b for a,b in zip(v,v[1:]))
    return SeriesStats(min(v),max(v),mean(v),median(v),pstdev(v) if len(v)>1 else 0.0,len(set(v)),sum(x==0 for x in v)/len(v),changes/max(1,len(v)-1))

def _ranks(v):
    order=sorted(range(len(v)),key=v.__getitem__); ranks=[0.0]*len(v); i=0
    while i<len(v):
        j=i+1
        while j<len(v) and v[order[j]]==v[order[i]]: j+=1
        r=(i+j-1)/2+1
        for k in range(i,j): ranks[order[k]]=r
        i=j
    return ranks

def pearson(a,b):
    if len(a)!=len(b) or len(a)<2: return float('nan')
    ma,mb=mean(a),mean(b); da=[x-ma for x in a]; db=[x-mb for x in b]
    den=math.sqrt(sum(x*x for x in da)*sum(x*x for x in db))
    return sum(x*y for x,y in zip(da,db))/den if den else float('nan')

def spearman(a,b): return pearson(_ranks(a),_ranks(b))

def lag_correlation(a,b,max_lag_samples):
    best=None
    for lag in range(-max_lag_samples,max_lag_samples+1):
        aa=a[max(0,-lag):len(a)-max(0,lag)]; bb=b[max(0,lag):len(b)-max(0,-lag)]
        r=pearson(aa,bb)
        if not math.isnan(r) and (best is None or abs(r)>abs(best[1])): best=(lag,r)
    return best
