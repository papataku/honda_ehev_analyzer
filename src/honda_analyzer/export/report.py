from __future__ import annotations
from html import escape
from pathlib import Path

def render_html_report(summary:dict):
    title=escape(str(summary.get("title","Honda e:HEV Analyzer Session Report")))
    sections=[]
    for key,val in summary.items():
        if key=="title": continue
        if isinstance(val,(list,tuple)):
            body="<ul>"+"".join(f"<li>{escape(str(x))}</li>" for x in val)+"</ul>"
        elif isinstance(val,dict):
            body="<table>"+"".join(f"<tr><th>{escape(str(k))}</th><td>{escape(str(v))}</td></tr>" for k,v in val.items())+"</table>"
        else: body=f"<p>{escape(str(val))}</p>"
        sections.append(f"<section><h2>{escape(str(key).replace('_',' ').title())}</h2>{body}</section>")
    return "<!doctype html><meta charset='utf-8'><title>"+title+"</title><style>body{font-family:-apple-system,BlinkMacSystemFont,sans-serif;max-width:1100px;margin:40px auto;padding:0 20px}table{border-collapse:collapse}th,td{padding:6px 12px;border-bottom:1px solid #ccc;text-align:left}code{font-family:ui-monospace}</style><h1>"+title+"</h1>"+"".join(sections)

def write_html_report(path, summary): Path(path).write_text(render_html_report(summary),encoding="utf-8")
