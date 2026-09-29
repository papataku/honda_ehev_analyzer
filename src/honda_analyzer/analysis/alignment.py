from __future__ import annotations
import math

def manual_offset(times, offset_s): return [float(t)+float(offset_s) for t in times]

def alignment_candidates(reference, target, max_lag_samples=100, top=5):
    """Return lag candidates without silently changing data. Positive lag means target is shifted later."""
    a=[float(x) for x in reference]; b=[float(x) for x in target]; out=[]
    for lag in range(-max_lag_samples,max_lag_samples+1):
        pairs=[]
        for i,x in enumerate(a):
            j=i-lag
            if 0<=j<len(b): pairs.append((x,b[j]))
        if len(pairs)<3: continue
        xa=[x for x,_ in pairs]; xb=[y for _,y in pairs]
        ma=sum(xa)/len(xa); mb=sum(xb)/len(xb)
        num=sum((x-ma)*(y-mb) for x,y in pairs); da=sum((x-ma)**2 for x in xa); db=sum((y-mb)**2 for y in xb)
        corr=num/math.sqrt(da*db) if da and db else 0.0
        out.append({"lag_samples":lag,"correlation":corr,"overlap":len(pairs)})
    return sorted(out,key=lambda x:(abs(x["correlation"]),x["overlap"]),reverse=True)[:top]
