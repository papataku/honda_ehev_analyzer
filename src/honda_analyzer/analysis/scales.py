SCALES=(1,1/2,1/4,1/8,1/10,1/16,1/20,1/32,1/50,1/64,1/100,1/128,1/256)
def scale_candidates(raw_values):
    if not raw_values: return []
    return [{'scale':s,'min':min(raw_values)*s,'max':max(raw_values)*s} for s in SCALES]
