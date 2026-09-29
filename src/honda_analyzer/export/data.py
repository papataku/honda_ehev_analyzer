from __future__ import annotations
import csv,json
from pathlib import Path

def export_json(path,obj): Path(path).write_text(json.dumps(obj,indent=2,ensure_ascii=False)+"\n",encoding="utf-8")
def export_csv(path,rows):
    rows=list(rows); fields=list(dict.fromkeys(k for r in rows for k in r)) if rows else []
    with Path(path).open("w",newline="",encoding="utf-8") as f:
        w=csv.DictWriter(f,fieldnames=fields); w.writeheader(); w.writerows(rows)
