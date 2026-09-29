import json
import pytest
from honda_analyzer.analysis.candidates import generator_rpm_candidate, mechanical_power_kw
from honda_analyzer.analysis.formula import evaluate, evaluate_many
from honda_analyzer.analysis.signal_definitions import SignalDefinition, save_signal_file, load_signal_file, smartring_export

def test_generator_candidate_separate_heuristic():
    engine=[0,0,1000,1500,2000,2500]
    gen=[0,0,800,1200,1600,2000]
    power=[0,1,5,10,15,20]
    c=generator_rpm_candidate(gen,engine,power)
    assert c.score >= .6
    assert any('engine RPM relationship' in x for x in c.evidence)

def test_mechanical_power():
    assert mechanical_power_kw(100, 3000) == pytest.approx(31.4159, rel=1e-4)

def test_formula_sandbox_is_safe():
    assert evaluate('(raw - 32768) / 4', 32772) == 1
    assert evaluate_many('raw/64',[0,64,128]) == [0,1,2]
    with pytest.raises(ValueError): evaluate('__import__("os").system("x")',1)

def test_signal_definition_roundtrip_and_export(tmp_path):
    defs=[SignalDefinition(name='Known',service='01',pid='0C',formula='raw/4',unit='rpm',status='KNOWN'),
          SignalDefinition(name='Guess',ecu='16',service='22',did='201A',offset=6,length=2,signed=True,endian='big',scale=.25,unit='rpm',status='CANDIDATE',evidence=['EV moving'])]
    p=tmp_path/'signals.json'; save_signal_file(p,'RP8',defs)
    meta, loaded=load_signal_file(p)
    assert meta['schema_version']==1 and loaded[1].did=='201A'
    exp=smartring_export(loaded)
    assert [x['name'] for x in exp['signals']] == ['Known']

def test_unverified_never_exports():
    d=SignalDefinition(name='Unknown motor',status='CANDIDATE')
    assert smartring_export([d])['signals']==[]
