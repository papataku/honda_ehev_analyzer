from pathlib import Path

ROOT=Path(__file__).resolve().parents[1]

def text(rel): return (ROOT/rel).read_text(encoding='utf-8')

def test_beginner_guardrails_are_present():
    app=text('src/honda_analyzer/gui/app.py')
    assert 'マーカーはライブ取得中だけ保存できます' in app
    assert 'RAW保存：ON（通常はONのまま）' in app
    assert '実車準備テストはPASS済みです' in app
    assert 'final_message=' in app

def test_analysis_buttons_have_prerequisite_guards():
    payload=text('src/honda_analyzer/gui/payload_analysis.py')
    corr=text('src/honda_analyzer/gui/correlation_analysis.py')
    assert 'self.run_btn.setEnabled(False)' in payload
    assert 'self.set_a_btn.setEnabled(False)' in payload
    assert 'self.run_btn.setEnabled(False)' in corr
