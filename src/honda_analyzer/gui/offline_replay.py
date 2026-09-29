from __future__ import annotations

import time

from PySide6.QtCore import QTimer, Qt, Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QHBoxLayout, QPushButton, QComboBox, QLabel,
    QTableWidget, QTableWidgetItem, QHeaderView, QPlainTextEdit, QSlider, QGridLayout, QSizePolicy,
)

from honda_analyzer.analysis.offline_replay import ReplayCursor, ReplayItem, load_session_replay
from honda_analyzer.analysis.standard_obd import decode_hybrid_ev_9a, decode_did2012_candidates
from honda_analyzer.gui.live_plot import LivePlotWidget
from honda_analyzer.gui.guide_widgets import guide_box
from honda_analyzer.gui.page_guides import PAGE_GUIDES


class OfflineReplayWidget(QWidget):
    statusChanged = Signal(str)
    sessionLoaded = Signal(int)

    def __init__(self, db_getter, writer_flush=None, parent=None):
        super().__init__(parent)
        self._db_getter = db_getter
        self._writer_flush = writer_flush
        self.cursor = ReplayCursor([])
        self.playing = False
        self.speed = 1.0
        self._wall_start = 0.0
        self._replay_start = 0.0
        self._last_marker_index = 0

        v = QVBoxLayout(self)
        v.addWidget(guide_box(PAGE_GUIDES['replay']))
        steps=QLabel('<b>使い方：</b> ① 記録を選ぶ → ②「読み込む」→ ③ 再生またはスライダーで移動 → ④ 比較したい時間帯をグラフの灰色帯で選ぶ → ⑤「6. データ比較」へ')
        steps.setWordWrap(True);steps.setStyleSheet('padding:8px; background: rgba(80,120,180,0.10);');v.addWidget(steps)

        top = QGridLayout()
        self.sessions = QComboBox(); self.sessions.setMinimumWidth(0); self.sessions.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.load_btn = QPushButton('記録を読み込む')
        self.play_btn = QPushButton('▶ 再生')
        self.pause_btn = QPushButton('■ 一時停止')
        self.step_btn = QPushButton('1件進む')
        self.speed_box = QComboBox(); self.speed_box.addItems(['0.5x','1x','2x','5x','10x','20x'])
        self.speed_box.setCurrentText('1x')
        self.info = QLabel('まだ記録を読み込んでいません'); self.info.setWordWrap(True)
        top.addWidget(QLabel('記録：'), 0, 0)
        top.addWidget(self.sessions, 0, 1, 1, 3)
        top.addWidget(self.load_btn, 0, 4)
        top.addWidget(self.play_btn, 1, 0)
        top.addWidget(self.pause_btn, 1, 1)
        top.addWidget(self.step_btn, 1, 2)
        top.addWidget(QLabel('速度：'), 1, 3)
        top.addWidget(self.speed_box, 1, 4)
        top.addWidget(self.info, 2, 0, 1, 5)
        top.setColumnStretch(1, 1); top.setColumnStretch(2, 1)
        v.addLayout(top)

        self.slider = QSlider(Qt.Horizontal); self.slider.setRange(0,1000); v.addWidget(self.slider)
        self.plot = LivePlotWidget(); self.plot.enable_selection(True); v.addWidget(self.plot)

        self.dashboard = QTableWidget(10,3)
        self.dashboard.setHorizontalHeaderLabels(['項目','値','単位/形式'])
        self.dashboard.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        replay_rows=[
            ('エンジン回転数','rpm'),('車速','km/h'),('冷却水温','°C'),
            ('HVバッテリーSOC（標準PID 5B）','%'),
            ('HVバッテリー電圧（標準PID 9A）','V'),
            ('HVバッテリー電流（+放電 / -充電）','A'),
            ('HVバッテリー電力（+放電 / -回生・充電）','kW'),
            ('Hybrid/EV PID 9A（RAW）','HEX'),('DID 2012（RAW/意味未確定）','HEX'),
            ('DID 2012 Byte 5：SOCミラー候補（未確定）','%')]
        for r,(n,u) in enumerate(replay_rows):
            self.dashboard.setItem(r,0,QTableWidgetItem(n)); self.dashboard.setItem(r,1,QTableWidgetItem('—')); self.dashboard.setItem(r,2,QTableWidgetItem(u))
        v.addWidget(self.dashboard)

        log_help=QLabel('下は保存されていたELM327の生ログです。通常は問題が起きたときだけ確認します。');log_help.setWordWrap(True);v.addWidget(log_help)
        self.log = QPlainTextEdit(); self.log.setReadOnly(True); self.log.document().setMaximumBlockCount(8000); v.addWidget(self.log)

        self.timer = QTimer(self); self.timer.timeout.connect(self._tick); self.timer.start(30)
        self.load_btn.clicked.connect(self.load_selected)
        self.play_btn.clicked.connect(self.play)
        self.pause_btn.clicked.connect(self.pause)
        self.step_btn.clicked.connect(self.step_once)
        self.speed_box.currentTextChanged.connect(self._speed_changed)
        self.slider.sliderReleased.connect(self._slider_seek)

    def refresh_sessions(self):
        db = self._db_getter(); current = self.sessions.currentData(); self.sessions.clear()
        for sid,started,ended,status,git,vehicle,notes in db.list_sessions():
            self.sessions.addItem(f'セッション {sid}  {started}  [{status}]', sid)
        if current is not None:
            i=self.sessions.findData(current)
            if i>=0:self.sessions.setCurrentIndex(i)

    def load_selected(self):
        sid = self.sessions.currentData()
        if sid is None:
            self.statusChanged.emit('読み込む記録がありません。先に実車データを取得してください。');return
        self.pause()
        if self._writer_flush:
            try:self._writer_flush()
            except Exception as e:
                self.statusChanged.emit(f'保存待ちデータの確定に失敗しました：{e}'); return
        items = load_session_replay(self._db_getter(), int(sid))
        self.cursor = ReplayCursor(items); self._replay_start=0.0
        self.plot.reset(); self.log.clear(); self._last_marker_index=0
        self._render_at(0.0, rebuild=True)
        self.info.setText(f'セッション {sid}：{len(items)}件 / {self.cursor.duration_s:.1f}秒')
        self.statusChanged.emit(f'保存済みセッション {sid} を読み込みました'); self.sessionLoaded.emit(int(sid))

    def numeric_series(self,name):
        if name in ('HV Battery Voltage','HV Battery Current','HV Battery Power'):
            out=[]
            for item in self.cursor.items:
                if item.kind!='command' or not item.success or str(item.command).replace(' ','').upper()!='019A':
                    continue
                hev=decode_hybrid_ev_9a(item.text or '')
                if hev is None: continue
                value={'HV Battery Voltage':hev.voltage_v,'HV Battery Current':hev.current_a,'HV Battery Power':hev.power_kw}[name]
                if value is not None: out.append((item.elapsed_s,float(value)))
            return out
        series=self.cursor.numeric_series_until(None).get(name,([],[])); return list(zip(series[0],series[1]))

    def play(self):
        if not self.cursor.items:
            self.statusChanged.emit('先に「記録を読み込む」を押してください。');return
        self.playing=True; current=self._current_elapsed(); self._replay_start=current; self._wall_start=time.monotonic()

    def pause(self):
        if self.playing:
            current=self._current_elapsed(); self.playing=False; self._replay_start=current

    def step_once(self):
        self.pause(); item=self.cursor.step()
        if item is not None:self._render_item(item); self._replay_start=item.elapsed_s
        else:self._replay_start=self.cursor.duration_s
        self._sync_position(self._replay_start)

    def _speed_changed(self,text):
        current=self._current_elapsed(); self.speed=float(text.rstrip('x')); self._replay_start=current; self._wall_start=time.monotonic()

    def _current_elapsed(self):
        if not self.playing:return min(self.cursor.duration_s, self._replay_start)
        return min(self.cursor.duration_s, self._replay_start+(time.monotonic()-self._wall_start)*self.speed)

    def _tick(self):
        if not self.playing:return
        target=self._current_elapsed()
        for item in self.cursor.consume_until(target):self._render_item(item)
        self._sync_position(target)
        if target >= self.cursor.duration_s:
            self._replay_start=target; self.playing=False; self.statusChanged.emit('オフライン再生が最後まで終わりました')

    def _slider_seek(self):
        if not self.cursor.items:return
        target=self.cursor.duration_s*(self.slider.value()/1000.0)
        self.pause(); self.cursor.seek(target); self._replay_start=target; self._render_at(target,rebuild=True)

    def _render_at(self,target,rebuild=False):
        if rebuild:
            self.plot.reset(); self.log.clear(); self.cursor.seek(target)
            for name,(x,y) in self.cursor.numeric_series_until(target).items():self.plot.update_series(name,x,y)
            for event in self.cursor.events_until(target):self.plot.add_marker(event.elapsed_s,event.event_kind or 'EVENT')
            for item in self.cursor.items:
                if item.elapsed_s > target:break
                if item.kind=='command':self._append_log(item)
            self._refresh_dashboard()
        self._sync_position(target)

    def _render_item(self,item:ReplayItem):
        if item.kind=='event':
            self.plot.add_marker(item.elapsed_s,item.event_kind or 'EVENT')
            self.log.appendPlainText(f'[{item.elapsed_s:8.3f}] MARKER {item.event_kind}: {item.note or ""}')
        else:
            self._append_log(item)
            if item.signal_name:
                self._refresh_dashboard(); series=self.cursor.numeric_series_until(item.elapsed_s)
                if item.signal_name in series:
                    x,y=series[item.signal_name];self.plot.update_series(item.signal_name,x,y)

    def _append_log(self,item):
        ok='OK' if item.success else 'FAIL'
        self.log.appendPlainText(f'[{item.elapsed_s:8.3f}] > {item.command} [{ok} {item.latency_ms or 0:.1f} ms]\n{item.text or ""}')

    def _latest_hev(self):
        upto=max(0,min(self.cursor.index,len(self.cursor.items)))
        for item in reversed(self.cursor.items[:upto]):
            if item.kind=='command' and item.success and str(item.command).replace(' ','').upper()=='019A':
                hev=decode_hybrid_ev_9a(item.text or '')
                if hev is not None:return hev
        return None

    def _refresh_dashboard(self):
        row={'Engine RPM':0,'Vehicle Speed':1,'Coolant':2,'HV Battery SOC':3,'Hybrid/EV 019A':7,'UDS DID 2012':8}
        for name,r in row.items():
            val=self.cursor.latest_values.get(name)
            if val is None: shown='データなし'
            elif name=='HV Battery SOC': shown=f'{float(val):.1f}'
            elif name in ('Engine RPM','Vehicle Speed','Coolant'): shown=f'{float(val):.0f}'
            else: shown=str(val)
            self.dashboard.setItem(r,1,QTableWidgetItem(shown))
        hev=self._latest_hev()
        vals=(None,None,None) if hev is None else (hev.voltage_v,hev.current_a,hev.power_kw)
        for r,val in zip((4,5,6),vals):
            text='データなし' if val is None else f'{val:.2f}'
            self.dashboard.setItem(r,1,QTableWidgetItem(text))
        # DID 0x2012 byte 5 is an evidence-backed candidate only.
        self.dashboard.setItem(9,1,QTableWidgetItem('データなし'))
        upto=max(0,min(self.cursor.index,len(self.cursor.items)))
        for item in reversed(self.cursor.items[:upto]):
            if item.kind=='command' and item.success and str(item.command).replace(' ','').upper()=='222012':
                cand=decode_did2012_candidates(item.text or '')
                if cand is not None and cand.soc_percent_candidate is not None:
                    self.dashboard.setItem(9,1,QTableWidgetItem(f'{cand.soc_percent_candidate:.0f}（候補）'))
                break

    def _sync_position(self,elapsed):
        duration=self.cursor.duration_s
        self.slider.blockSignals(True); self.slider.setValue(0 if duration<=0 else int(max(0,min(1000,1000*elapsed/duration)))); self.slider.blockSignals(False)
        self.info.setText(f'{elapsed:.1f} / {duration:.1f}秒  {self.cursor.index}/{len(self.cursor.items)}件  再生速度 {self.speed:g}x')
