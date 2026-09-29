from pathlib import Path

from honda_analyzer.gui.layout_policy import recommended_window_size


def test_recommended_window_size_never_exceeds_screen():
    for width, height in [(1440, 900), (1280, 800), (1024, 768), (800, 600), (640, 480)]:
        w, h = recommended_window_size(width, height)
        assert 1 <= w <= width
        assert 1 <= h <= height


def test_recommended_window_size_caps_large_monitors():
    assert recommended_window_size(2560, 1440) == (1280, 820)


def test_app_no_longer_uses_legacy_1480x940_fixed_start():
    app = Path('src/honda_analyzer/gui/app.py').read_text(encoding='utf-8')
    assert 'resize(1480, 940)' not in app
    assert 'QScrollArea' in app
    assert 'setUsesScrollButtons(True)' in app
