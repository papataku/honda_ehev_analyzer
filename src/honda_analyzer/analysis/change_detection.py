from collections import Counter

def byte_activity(payloads):
    if not payloads: return []
    width=max(map(len,payloads)); out=[]
    for i in range(width):
        vals=[p[i] for p in payloads if i<len(p)]
        changes=sum(a!=b for a,b in zip(vals,vals[1:]))
        out.append({'offset':i,'samples':len(vals),'unique':len(set(vals)),'change_rate':changes/max(1,len(vals)-1),'constant':len(set(vals))<=1})
    return out

def detect_counter(values, modulus=256):
    if len(values)<4: return False
    good=sum(((b-a)%modulus)==1 for a,b in zip(values,values[1:]))
    return good/(len(values)-1)>=0.8

def bit_toggle_counts(payloads):
    if not payloads: return []
    width=min(map(len,payloads)); result=[]
    for off in range(width):
        for bit in range(8):
            vals=[(p[off]>>bit)&1 for p in payloads]
            toggles=sum(a!=b for a,b in zip(vals,vals[1:]))
            result.append((off,bit,toggles))
    return result
