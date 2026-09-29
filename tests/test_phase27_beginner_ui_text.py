from honda_analyzer.gui.page_guides import PAGE_GUIDES, RECOMMENDED_FLOW


def test_every_main_page_has_beginner_guidance_in_japanese():
    expected={'start','connection','live','ecu','drive','replay','payload','correlation','sessions','terminal'}
    assert expected <= set(PAGE_GUIDES)
    for key in expected:
        p=PAGE_GUIDES[key]
        assert all(p.get(x) for x in ('title','purpose','learn','requires'))
        assert any(ord(ch)>127 for ch in ''.join(p.values()))


def test_recommended_flow_is_explicit_and_ordered():
    assert len(RECOMMENDED_FLOW) >= 7
    assert 'BLE' in RECOMMENDED_FLOW[1]
    assert 'ライブ表示' in RECOMMENDED_FLOW[3]
    assert 'ECU確認' in RECOMMENDED_FLOW[4]
    assert '記録を見る' in RECOMMENDED_FLOW[-1]


def test_app_exposes_japanese_beginner_tab_flow_in_source():
    from pathlib import Path
    app=(Path(__file__).resolve().parents[1]/'src/honda_analyzer/gui/app.py').read_text(encoding='utf-8')
    for label in ('はじめに','1. 接続・準備','2. ライブ表示','3. ECU確認','4. 走行記録','5. 記録を見る','6. データ比較','7. 相関を見る','記録管理','上級者：ELM327端末'):
        assert label in app
    assert '完全停止・Pレンジ' in (Path(__file__).resolve().parents[1]/'src/honda_analyzer/gui/ecu_discovery.py').read_text(encoding='utf-8')
