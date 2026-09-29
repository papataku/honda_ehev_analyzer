from __future__ import annotations


def recommended_window_size(available_width: int, available_height: int) -> tuple[int, int]:
    """Return a conservative initial window size that fits the usable desktop.

    The window should never start larger than the usable screen. On normal laptop
    screens it uses about 88% of the width and 86% of the height, capped so the
    analyzer does not dominate large external monitors.
    """
    aw = max(1, int(available_width))
    ah = max(1, int(available_height))
    target_w = min(1280, max(760, int(aw * 0.88)))
    target_h = min(820, max(560, int(ah * 0.86)))
    return min(target_w, aw), min(target_h, ah)
