from __future__ import annotations
import math, statistics

def percentile(values,p):
    v=sorted(float(x) for x in values)
    if not v:return None
    k=(len(v)-1)*p/100; lo=math.floor(k); hi=math.ceil(k)
    return v[lo] if lo==hi else v[lo]*(hi-k)+v[hi]*(k-lo)

def timing_stats(latencies_ms, duration_s=None, notifications=0, byte_count=0):
    v=[float(x) for x in latencies_ms]
    d=float(duration_s or 0)
    return {'count':len(v),'average_ms':statistics.fmean(v) if v else None,'median_ms':statistics.median(v) if v else None,
            'p95_ms':percentile(v,95),'p99_ms':percentile(v,99),'max_ms':max(v) if v else None,
            'request_per_s':len(v)/d if d>0 else None,'notification_per_s':notifications/d if d>0 else None,'bytes_per_s':byte_count/d if d>0 else None}
