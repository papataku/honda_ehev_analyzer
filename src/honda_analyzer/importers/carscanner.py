from __future__ import annotations
import csv, io, re
from dataclasses import dataclass
from pathlib import Path

@dataclass(frozen=True)
class ImportedSeries:
    source: str
    time_column: str
    rows: list[dict]
    columns: list[str]
    delimiter: str
    decimal: str

_TIME_NAMES=("time","timestamp","date","datetime","time (s)","seconds")

def _detect(text:str):
    sample=text[:8192]
    try: delim=csv.Sniffer().sniff(sample, delimiters=",;\t|").delimiter
    except csv.Error: delim="," if sample.count(",") >= sample.count(";") else ";"
    numeric=re.findall(r'(?<!\d)(?:-?\d+)([.,])\d+(?!\d)', sample)
    decimal="," if numeric.count(",")>numeric.count(".") and delim!="," else "."
    return delim,decimal

def import_carscanner(path, delimiter=None, decimal=None):
    p=Path(path); raw=p.read_bytes()
    text=raw.decode("utf-8-sig", errors="replace")
    auto_delim,auto_decimal=_detect(text); delimiter=delimiter or auto_delim; decimal=decimal or auto_decimal
    reader=csv.DictReader(io.StringIO(text), delimiter=delimiter)
    columns=reader.fieldnames or []
    time_col=next((c for c in columns if c.strip().lower() in _TIME_NAMES), columns[0] if columns else "")
    rows=[]
    for r in reader:
        out={}
        for k,v in r.items():
            if v is None: out[k]=None; continue
            s=v.strip()
            n=s.replace(decimal,".") if decimal != "." else s
            try: out[k]=float(n) if any(ch in n.lower() for ch in (".","e")) else int(n)
            except ValueError: out[k]=s
        rows.append(out)
    return raw, ImportedSeries("Car Scanner",time_col,rows,columns,delimiter,decimal)
