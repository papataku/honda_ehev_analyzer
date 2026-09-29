from __future__ import annotations
from dataclasses import dataclass

@dataclass(frozen=True)
class PollItem:
    name:str; period_ms:float; latency_ms:float

def simulate(items, horizon_ms=10000):
    """Deterministic single-server ELM scheduler simulation (EDF by due time/name)."""
    items=list(items); events=[]
    for x in items:
        t=0.0
        while t < horizon_ms: events.append((t,x.name,x)); t+=x.period_ms
    events.sort(key=lambda e:(e[0],e[1])); server=0.0; per={x.name:{'requested':0,'completed':0,'deadline_miss':0,'queue_ms':[]} for x in items}
    busy=0.0
    for due,name,x in events:
        s=per[name]; s['requested']+=1; start=max(server,due); q=start-due; finish=start+x.latency_ms
        s['queue_ms'].append(q); s['completed']+=1; s['deadline_miss']+=int(finish>due+x.period_ms); server=finish; busy+=x.latency_ms
    for x in items:
        s=per[x.name]; s['achievable_hz']=s['completed']/(horizon_ms/1000); s['avg_queue_ms']=sum(s['queue_ms'])/len(s['queue_ms']) if s['queue_ms'] else 0; del s['queue_ms']
    return {'horizon_ms':horizon_ms,'utilization':busy/horizon_ms,'signals':per,'overloaded':busy>horizon_ms}

def recommend_rate(latencies_ms, safety_utilization=.7):
    if not latencies_ms:return None
    p95=sorted(latencies_ms)[max(0,int(.95*(len(latencies_ms)-1)))]
    return safety_utilization*1000.0/p95 if p95>0 else None
