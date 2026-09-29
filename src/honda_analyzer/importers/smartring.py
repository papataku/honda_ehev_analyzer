from __future__ import annotations
import csv, io, json
from pathlib import Path
from .carscanner import ImportedSeries

def import_smartring(path):
    p=Path(path); raw=p.read_bytes(); text=raw.decode("utf-8-sig",errors="replace"); suffix=p.suffix.lower()
    if suffix in {".jsonl",".ndjson"}:
        rows=[json.loads(x) for x in text.splitlines() if x.strip()]
    elif suffix==".json":
        obj=json.loads(text); rows=obj if isinstance(obj,list) else obj.get("samples",obj.get("rows",[]))
    else:
        try: delim=csv.Sniffer().sniff(text[:8192],delimiters=",;\t|").delimiter
        except csv.Error: delim=","
        rows=list(csv.DictReader(io.StringIO(text),delimiter=delim))
    cols=list(dict.fromkeys(k for r in rows for k in r)) if rows else []
    tc=next((x for x in cols if x.lower() in {"timestamp","time","ts","time_ms","time_s"}),cols[0] if cols else "")
    return raw, ImportedSeries("SmartRing",tc,rows,cols,"," if suffix==".csv" else "", ".")
