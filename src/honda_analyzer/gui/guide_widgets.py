from __future__ import annotations
from PySide6.QtWidgets import QFrame, QLabel, QVBoxLayout


def guide_box(page: dict) -> QFrame:
    box = QFrame()
    box.setFrameShape(QFrame.StyledPanel)
    box.setStyleSheet('QFrame { background: rgba(80,120,180,0.10); border-radius: 6px; padding: 5px; }')
    v = QVBoxLayout(box)
    title = QLabel(f'<b>{page["title"]}</b>')
    title.setStyleSheet('font-size: 18px;')
    body = QLabel(
        f'<b>ここですること：</b>{page["purpose"]}<br>'
        f'<b>ここで分かること：</b>{page["learn"]}<br>'
        f'<b>先に必要なこと：</b>{page["requires"]}'
    )
    body.setWordWrap(True)
    v.addWidget(title); v.addWidget(body)
    return box
