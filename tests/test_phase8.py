import json
from honda_analyzer.importers.carscanner import import_carscanner
from honda_analyzer.importers.smartring import import_smartring
from honda_analyzer.analysis.alignment import alignment_candidates,manual_offset
from honda_analyzer.export.report import render_html_report
from honda_analyzer.export.data import export_json,export_csv
from honda_analyzer.analysis.signal_definitions import SignalDefinition,smartring_export

def test_carscanner_semicolon_decimal_comma(tmp_path):
    p=tmp_path/'car.csv'; p.write_text('Time;Engine RPM;Vehicle speed\n0,0;0;0\n1,0;1200;20\n',encoding='utf-8')
    raw,s=import_carscanner(p)
    assert raw.startswith(b'Time') and s.delimiter==';' and s.decimal==',' and s.rows[1]['Vehicle speed']==20

def test_smartring_jsonl(tmp_path):
    p=tmp_path/'ring.jsonl'; p.write_text('{"timestamp":1,"rpm":0}\n{"timestamp":2,"rpm":100}\n')
    raw,s=import_smartring(p); assert len(s.rows)==2 and s.time_column=='timestamp'

def test_alignment_is_candidate_not_mutation():
    a=[0,1,2,3,4,5]; b=[0,0,1,2,3,4]
    c=alignment_candidates(a,b,2); assert c and 'lag_samples' in c[0]
    assert manual_offset([1,2],.5)==[1.5,2.5]

def test_report_escapes_html():
    h=render_html_report({'title':'T','notes':'<script>x</script>','positive_dids':['2012']})
    assert '<script>' not in h and '&lt;script&gt;' in h

def test_exports(tmp_path):
    j=tmp_path/'x.json'; c=tmp_path/'x.csv'; export_json(j,{'a':1}); export_csv(c,[{'a':1,'b':2}])
    assert json.loads(j.read_text())['a']==1 and 'a,b' in c.read_text()

def test_smartring_only_known_verified():
    obj=smartring_export([SignalDefinition('rpm',status='KNOWN'),SignalDefinition('guess',status='CANDIDATE')])
    assert [x['name'] for x in obj['signals']]==['rpm']
