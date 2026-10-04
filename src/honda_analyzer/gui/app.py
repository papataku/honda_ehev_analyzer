from __future__ import annotations

import asyncio
import subprocess
import sys
import time
from datetime import datetime, timezone
from pathlib import Path

from PySide6.QtCore import QTimer, Qt
from PySide6.QtWidgets import (
    QApplication, QMainWindow, QWidget, QVBoxLayout, QHBoxLayout, QPushButton,
    QComboBox, QPlainTextEdit, QLineEdit, QTabWidget, QTreeWidget,
    QTreeWidgetItem, QLabel, QTableWidget, QTableWidgetItem, QInputDialog,
    QHeaderView, QCheckBox, QGroupBox, QScrollArea, QFrame, QSizePolicy, QGridLayout,
)

from honda_analyzer import __version__
from honda_analyzer.build_info import BUILD_ID
from honda_analyzer.transport.ble import scan_devices, KW905BleTransport
from honda_analyzer.protocol.elm_session import ElmSession, initialize, is_read_only_vehicle_command
from honda_analyzer.protocol.can_header import elm327_header_commands, split_29bit_header
from honda_analyzer.protocol.elm_text import find_uds_22_payload
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.storage.async_writer import AsyncSessionWriter
from honda_analyzer.analysis.readiness import run_vehicle_readiness
from honda_analyzer.diagnostics import live_quality_from_db
from honda_analyzer.debug_bundle import create_session_debug_bundle
from honda_analyzer.gui.drive_mode import MARKERS, communication_alert
from honda_analyzer.analysis.live_polling import DueScheduler, decode_poll, DEFAULT_POLLS, dynamic_state_specs, PollSpec
from honda_analyzer.analysis.live_series import LiveSeriesBuffer, numeric_value
from honda_analyzer.gui.live_plot import LivePlotWidget
from honda_analyzer.gui.payload_analysis import PayloadAnalysisWidget
from honda_analyzer.gui.correlation_analysis import CorrelationAnalysisWidget
from honda_analyzer.gui.offline_replay import OfflineReplayWidget
from honda_analyzer.gui.ecu_discovery import EcuDiscoveryWidget
from honda_analyzer.gui.guide_widgets import guide_box
from honda_analyzer.gui.page_guides import PAGE_GUIDES, RECOMMENDED_FLOW
from honda_analyzer.gui.layout_policy import recommended_window_size
from honda_analyzer.gui.operation_gate import OperationGate
from honda_analyzer.analysis.payload_workspace import command_payloads, differential, activity, heatmap_data, expanded_candidates
from honda_analyzer.analysis.field_correlation import analyze_field, field_series, align_nearest
from honda_analyzer.analysis.response_inventory import diagnostic_response_inventory
from honda_analyzer.analysis.did_discovery import AsyncDidDiscovery, DidProbeOutcome, classify_uds_22_text
from honda_analyzer.analysis.did_scan_timing import profile_for_rate
from honda_analyzer.analysis.did_drive import rank_did_fields, PositiveDidRoundRobin
from honda_analyzer.analysis.standard_obd import (
    STANDARD_PIDS, SUPPORT_BITMAP_PIDS, supported_pids_from_bitmap_response,
    should_continue_bitmap, state_pid_choices, decode_standard_pid, mode01_command,
    decode_hybrid_ev_9a, decode_did2012_candidates,
)
from honda_analyzer.analysis.auto_drive_state import AutoDriveStateTracker
from honda_analyzer.analysis.ecu_census import (
    passive_ecu_census, SAFE_CENSUS_REQUESTS, physical_request_id_for_ecu,
    expected_response_id_for_ecu, response_ecu_from_29bit,
)

UTC = lambda: datetime.now(timezone.utc).isoformat()


def _git_commit():
    try:
        return subprocess.check_output(['git', 'rev-parse', 'HEAD'], stderr=subprocess.DEVNULL, text=True).strip()
    except Exception:
        return BUILD_ID


class MainWindow(QMainWindow):
    def __init__(self):
        super().__init__()
        self.setWindowTitle('Honda e:HEV Analyzer — 実車データ取得・解析')
        # Do not let page contents force the window larger than a MacBook screen.
        # Every tab is scrollable, so the user can freely resize the window.
        self.setMinimumSize(640, 480)
        screen = QApplication.primaryScreen()
        if screen is not None:
            available = screen.availableGeometry()
            target_w, target_h = recommended_window_size(available.width(), available.height())
            self.resize(target_w, target_h)
        else:
            self.resize(1100, 720)

        self.transport = None
        self.session = None
        self.adapter_ready = False
        self.readiness_passed = False
        self.connection_gate = OperationGate()
        self.writer = None
        self.analysis_sid = None
        self.scan_rssi = {}
        self.current_rssi = None
        self.db = None
        self.sid = None
        self.capture_enabled = True
        self.last_quality = None
        self.live_polling = False
        self.session_dirty = False
        self.poll_scheduler = DueScheduler()
        self.poll_task = None
        self.active_header = None
        self.active_can_priority = None
        self.live_poll_errors = 0
        self.live_decode_errors = 0
        self.last_analysis_range = None
        self.last_vehicle_speed = None
        self.session_t0 = time.monotonic()
        self.live_series = {n: LiveSeriesBuffer() for n in ('Engine RPM', 'Vehicle Speed', 'Coolant', 'HV Battery SOC', 'HV Battery Voltage', 'HV Battery Current', 'HV Battery Power')}
        self.supported_mode01_pids = set()
        self.state_pid_map = {}
        self.auto_state = AutoDriveStateTracker()
        self.last_auto_state_label = None
        self.pending_auto_state_label = None
        self.pending_auto_state_since = None
        self.mode01_sweep = []
        self.mode01_sweep_index = 0
        self.next_sweep_due = 0.0
        self.mode01_sweep_interval_s = 2.0
        self.did_discovery_task = None
        self.did_discovery_stop = False
        self.did_sweep_plan = []
        self.did_sweep_index = 0
        self.did_round_robin = PositiveDidRoundRobin(())
        self.did_sweep_interval_s = 3.0
        self.next_did_sweep_due = 0.0
        self.did_sweep_samples = 0

        self.tabs = QTabWidget()
        self.tabs.setMinimumSize(0, 0)
        self.tabs.setDocumentMode(True)
        self.tabs.setElideMode(Qt.ElideRight)
        self.tabs.tabBar().setUsesScrollButtons(True)
        self.tabs.tabBar().setExpanding(False)
        self.setCentralWidget(self.tabs)

        def add_page(widget, title):
            # A scroll area breaks the child page's minimum-size pressure on the
            # main window. This is essential on 13-inch MacBooks and when macOS
            # display scaling makes the logical desktop smaller.
            scroll = QScrollArea()
            scroll.setWidgetResizable(True)
            scroll.setFrameShape(QFrame.NoFrame)
            scroll.setHorizontalScrollBarPolicy(Qt.ScrollBarAsNeeded)
            scroll.setVerticalScrollBarPolicy(Qt.ScrollBarAsNeeded)
            scroll.setMinimumSize(0, 0)
            scroll.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Expanding)
            widget.setMinimumSize(0, 0)
            widget.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Preferred)
            scroll.setWidget(widget)
            self.tabs.addTab(scroll, title)
            return scroll

        # 0. Start / onboarding
        start = QWidget(); sv = QVBoxLayout(start)
        sv.addWidget(guide_box(PAGE_GUIDES['start']))
        flow = QGroupBox('おすすめの使い方')
        fv = QVBoxLayout(flow)
        for line in RECOMMENDED_FLOW:
            lab = QLabel(line); lab.setWordWrap(True); lab.setStyleSheet('font-size: 15px; padding: 3px;'); fv.addWidget(lab)
        sv.addWidget(flow)
        self.start_state = QLabel(); self.start_state.setWordWrap(True)
        self.start_state.setStyleSheet('font-size: 15px; padding: 10px; background: rgba(80,150,100,0.10);')
        sv.addWidget(self.start_state)
        note = QLabel('<b>迷ったら：</b>上から順番にタブを進めてください。「上級者向け：ELM327端末」は通常操作では使いません。')
        note.setWordWrap(True); sv.addWidget(note); sv.addStretch(1)
        add_page(start, 'はじめに')

        # 1. Connection / readiness
        connection = QWidget(); cv = QVBoxLayout(connection)
        cv.addWidget(guide_box(PAGE_GUIDES['connection']))
        self.connection_next = QLabel('次にすること：BLE機器を検索してください。')
        self.connection_next.setWordWrap(True); self.connection_next.setStyleSheet('font-size: 16px; font-weight: 600; padding: 8px;')
        cv.addWidget(self.connection_next)
        bar = QGridLayout()
        self.devices = QComboBox(); self.devices.setMinimumWidth(0); self.devices.setSizePolicy(QSizePolicy.Expanding, QSizePolicy.Fixed)
        self.scan_btn = QPushButton('① BLE機器を検索')
        self.readiness_btn = QPushButton('② 選択したKW905で実車準備テスト')
        self.connect_btn = QPushButton('③ KW905へ接続')
        self.disconnect_btn = QPushButton('切断')
        self.capture_btn = QPushButton('RAW保存：ON（通常はONのまま）'); self.capture_btn.setCheckable(True); self.capture_btn.setChecked(True)
        bar.addWidget(self.scan_btn, 0, 0)
        bar.addWidget(self.devices, 0, 1, 1, 2)
        bar.addWidget(self.readiness_btn, 1, 0)
        bar.addWidget(self.connect_btn, 1, 1)
        bar.addWidget(self.disconnect_btn, 1, 2)
        bar.addWidget(self.capture_btn, 2, 0, 1, 3)
        bar.setColumnStretch(1, 1); bar.setColumnStretch(2, 1)
        cv.addLayout(bar)
        explain = QLabel('実車準備テストは「このMac・KW905・車が正しく通信できるか」を確認する検査です。終了時に一度切断します。PASSしたら故障診断が終わったという意味ではなく、このアプリで読取りを始められる状態という意味です。次に「③ KW905へ接続」を押してください。')
        explain.setWordWrap(True); cv.addWidget(explain)
        self.gatt = QTreeWidget(); self.gatt.setHeaderLabels(['BLE Service / Characteristic', '属性'])
        self.notify = QPlainTextEdit(); self.notify.setReadOnly(True); self.notify.document().setMaximumBlockCount(5000)
        self.notify.setPlaceholderText('ここにはBLEのRAW受信ログが表示されます。普段は内容を理解する必要はありません。')
        cv.addWidget(QLabel('BLE詳細（問題調査用。通常は見るだけでOK）'))
        cv.addWidget(self.gatt, 1); cv.addWidget(self.notify, 1)
        add_page(connection, '1. 接続・準備')

        # 2. Live dashboard
        live = QWidget(); lv = QVBoxLayout(live)
        lv.addWidget(guide_box(PAGE_GUIDES['live']))
        self.status = QLabel('未接続'); self.status.setWordWrap(True); self.status.setStyleSheet('font-size: 16px; font-weight: 600;')
        self.quality = QLabel('通信品質：まだデータがありません')
        self.live_next = QLabel('開始するには「1. 接続・準備」でKW905へ接続してください。'); self.live_next.setWordWrap(True)
        lv.addWidget(self.status); lv.addWidget(self.quality); lv.addWidget(self.live_next)
        self.dashboard = QTableWidget(10, 3)
        self.dashboard.setHorizontalHeaderLabels(['項目', '現在値', '単位/形式'])
        self.dashboard.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch)
        display_rows = [
            ('エンジン回転数', 'rpm'), ('車速', 'km/h'), ('冷却水温', '°C'),
            ('HVバッテリーSOC（標準PID 5B）', '%'),
            ('HVバッテリー電圧（標準PID 9A）', 'V'),
            ('HVバッテリー電流（+放電 / -充電）', 'A'),
            ('HVバッテリー電力（+放電 / -回生・充電）', 'kW'),
            ('Hybrid/EV PID 9A（RAW）', 'HEX'), ('DID 2012（RAW/意味未確定）', 'HEX'),
            ('DID 2012 Byte 5：SOCミラー候補（未確定）', '%'),
        ]
        for r, (n, u) in enumerate(display_rows):
            self.dashboard.setItem(r, 0, QTableWidgetItem(n)); self.dashboard.setItem(r, 1, QTableWidgetItem('—')); self.dashboard.setItem(r, 2, QTableWidgetItem(u))
        lv.addWidget(self.dashboard)
        statebox=QGroupBox('自動走行状態（運転中の手動操作は不要）')
        statev=QVBoxLayout(statebox)
        self.auto_state_label=QLabel('判定待ち：ライブ取得開始後、車速とRPMから自動判定します。')
        self.auto_state_label.setWordWrap(True); self.auto_state_label.setStyleSheet('font-size: 18px; font-weight: 700; padding: 6px;')
        self.auto_state_detail=QLabel('アクセル等に加え、標準PID 9AのHV電力も判定に使います。減速中にHV電力が負なら「回生」と確認できます。')
        self.auto_state_detail.setWordWrap(True)
        self.sweep_status=QLabel('標準PID巡回ダンプ：ライブ開始時に車両の対応PIDを自動確認します。')
        self.sweep_status.setWordWrap(True)
        self.did_sweep_status=QLabel('Positive DID巡回：DID探索で見つかったDIDがあれば、走行中に空き時間で自動取得します。')
        self.did_sweep_status.setWordWrap(True)
        statev.addWidget(self.auto_state_label); statev.addWidget(self.auto_state_detail); statev.addWidget(self.sweep_status); statev.addWidget(self.did_sweep_status)
        lv.addWidget(statebox)
        self.live_plot = LivePlotWidget(); lv.addWidget(self.live_plot, 1)
        ph = QHBoxLayout()
        self.poll_start = QPushButton('▶ ライブ取得を開始')
        self.poll_stop = QPushButton('■ ライブ取得を停止')
        self.live_new_session_btn = QPushButton('次の記録を開始')
        ph.addWidget(self.poll_start); ph.addWidget(self.poll_stop); ph.addWidget(self.live_new_session_btn); ph.addStretch(1); lv.addLayout(ph)
        marker_title = QLabel('任意：助手席の人が補足したい場合だけ手動マーカーを付ける（運転者は操作しない）：')
        marker_title.setWordWrap(True); lv.addWidget(marker_title)
        mh = QGridLayout(); self.live_marker_buttons=[]
        for i, (key, label) in enumerate([('STOP','停止'),('EV','EV走行'),('ENGINE ON','エンジンON'),('ACCEL','加速'),('CRUISE','定速'),('REGEN','回生'),('CUSTOM','その他')]):
            b = QPushButton(label); b.clicked.connect(lambda _=False, k=key: self.add_marker(k)); mh.addWidget(b, i // 4, i % 4); self.live_marker_buttons.append(b)
        for c in range(4): mh.setColumnStretch(c, 1)
        lv.addLayout(mh)
        self.finish_btn = QPushButton('現在の記録を終了してデバッグ用ZIPを作成')
        self.finish_btn.clicked.connect(self.finish_and_bundle); lv.addWidget(self.finish_btn)
        add_page(live, '2. ライブ表示')

        # 3. ECU discovery
        self.ecu_discovery = EcuDiscoveryWidget()
        self.ecu_discovery.requestPassive.connect(self.run_passive_ecu_census)
        self.ecu_discovery.requestActive.connect(lambda: self.spawn(self.run_active_ecu_census()))
        self.ecu_discovery.requestProbe.connect(lambda ecu: self.spawn(self.run_stationary_probe(ecu)))
        self.ecu_discovery.requestDidScan.connect(lambda cfg: self.spawn(self.run_did_discovery(cfg)))
        self.ecu_discovery.requestDidStop.connect(self.stop_did_discovery)
        self.ecu_discovery.requestDidAnalysis.connect(lambda sid: self.spawn(self.run_did_drive_analysis(sid)))
        add_page(self.ecu_discovery, '3. ECU確認')

        # 4. Drive test mode
        drive = QWidget(); dv = QVBoxLayout(drive)
        dv.addWidget(guide_box(PAGE_GUIDES['drive']))
        drive_scope = QLabel('<b>走行中は基本的に操作不要です：</b> RPM/車速/水温/HV SOC/HV電圧・電流・電力/2012に加え、車両が対応する標準Mode 01 PIDを低速巡回保存します。速度・RPM・アクセル・HV電力から走行状態と回生を自動判定します。各要求に返った全response CAN IDのRAWも保存します。ただし車内CANバス全フレームの受動キャプチャではありません。')
        drive_scope.setWordWrap(True); drive_scope.setStyleSheet('padding: 8px; background: rgba(80,120,180,0.10);'); dv.addWidget(drive_scope)
        self.drive_banner = QLabel('ライブ取得を開始してから使います')
        self.drive_banner.setAlignment(Qt.AlignCenter); self.drive_banner.setMinimumHeight(64); self.drive_banner.setWordWrap(True); self.drive_banner.setStyleSheet('font-size: 24px; font-weight: 700;')
        self.drive_comm = QLabel('通信品質：まだデータがありません'); self.drive_comm.setAlignment(Qt.AlignCenter); self.drive_comm.setStyleSheet('font-size: 22px;')
        self.drive_last = QLabel('最後のマーカー：—'); self.drive_last.setAlignment(Qt.AlignCenter); self.drive_last.setStyleSheet('font-size: 20px;')
        dv.addWidget(self.drive_banner); dv.addWidget(self.drive_comm); dv.addWidget(self.drive_last)
        grid = QGridLayout(); self.drive_marker_buttons=[]
        drive_labels = {'STOP':'停止', 'EV':'EV', 'ENGINE ON':'エンジンON', 'ACCEL':'加速', 'CRUISE':'定速', 'REGEN':'回生', 'CUSTOM':'その他'}
        for i, key in enumerate(MARKERS):
            b = QPushButton(drive_labels.get(key, key)); b.setMinimumHeight(82); b.setStyleSheet('font-size: 20px; font-weight: 650;')
            b.clicked.connect(lambda _=False, k=key: self.add_marker(k)); grid.addWidget(b, i // 4, i % 4); self.drive_marker_buttons.append(b)
        for c in range(4): grid.setColumnStretch(c, 1)
        dv.addLayout(grid)
        self.drive_finish_btn = QPushButton('走行記録を終了・保存してデバッグ用ZIPを作成')
        self.drive_finish_btn.setMinimumHeight(56); self.drive_finish_btn.setStyleSheet('font-size: 18px; font-weight: 700;'); self.drive_finish_btn.clicked.connect(self.finish_and_bundle); dv.addWidget(self.drive_finish_btn)
        add_page(drive, '4. 走行記録')

        # 5. Offline replay
        self.offline_replay = OfflineReplayWidget(lambda: self.db, self._flush_writer)
        self.offline_replay.statusChanged.connect(self.status.setText)
        self.offline_replay.sessionLoaded.connect(self.use_offline_analysis_session)
        self.offline_replay.plot.rangeSelected.connect(lambda a,b:self.capture_analysis_range(a,b,'offline'))
        add_page(self.offline_replay, '5. 記録を見る')

        # 6. Payload analysis
        pa = QWidget(); pav = QVBoxLayout(pa)
        self.payload_analysis = PayloadAnalysisWidget(); pav.addWidget(self.payload_analysis)
        add_page(pa, '6. データ比較')
        self._range_stage = 'A'
        self.live_plot.enable_selection(True)
        self.live_plot.rangeSelected.connect(lambda a,b:self.capture_analysis_range(a,b,'live'))
        self.payload_analysis.requestAnalysis.connect(self.run_payload_analysis)
        self.payload_analysis.fieldSelected.connect(self.filter_expanded_fields)
        self.payload_analysis.assignRange.connect(self.assign_payload_range)

        # 7. Correlation
        ca = QWidget(); cav = QVBoxLayout(ca)
        self.correlation_analysis = CorrelationAnalysisWidget(); cav.addWidget(self.correlation_analysis)
        add_page(ca, '7. 相関を見る')
        self.correlation_analysis.requestCorrelation.connect(self.run_field_correlation)

        # Session management
        sessions = QWidget(); sesv = QVBoxLayout(sessions)
        sesv.addWidget(guide_box(PAGE_GUIDES['sessions']))
        sh=QLabel('通常はここを操作しなくて大丈夫です。アプリ起動時に新しい記録が自動で作られます。ライブ取得中は記録の切替をできないようにしています。'); sh.setWordWrap(True); sesv.addWidget(sh)
        sb = QHBoxLayout(); self.new_btn = QPushButton('新しい記録を開始'); self.close_btn = QPushButton('現在の記録を閉じる'); self.refresh_btn = QPushButton('一覧を更新')
        sb.addWidget(self.new_btn); sb.addWidget(self.close_btn); sb.addWidget(self.refresh_btn); sb.addStretch(1); sesv.addLayout(sb)
        self.sessions = QTableWidget(0, 7)
        self.sessions.setHorizontalHeaderLabels(['ID','開始UTC','終了UTC','状態','Git/Build','車両','メモ'])
        self.sessions.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); sesv.addWidget(self.sessions)
        add_page(sessions, '記録管理')

        # Advanced ELM terminal, intentionally last.
        terminal = QWidget(); tv = QVBoxLayout(terminal)
        tv.addWidget(guide_box(PAGE_GUIDES['terminal']))
        self.term = QPlainTextEdit(); self.term.setReadOnly(True); self.term.document().setMaximumBlockCount(10000)
        self.cmd = QLineEdit(); self.cmd.setPlaceholderText('例：ATI')
        send = QPushButton('コマンドを送信')
        self.safe_terminal = QCheckBox('安全モード：AT / 01 / 09 / 22 の読取りだけ許可する')
        self.safe_terminal.setChecked(True)
        hb = QHBoxLayout(); hb.addWidget(self.cmd); hb.addWidget(send)
        tv.addWidget(self.safe_terminal); tv.addLayout(hb); tv.addWidget(self.term)
        add_page(terminal, '上級者：ELM327端末')

        # Connections
        self.poll_start.clicked.connect(self.start_live_polling)
        self.poll_stop.clicked.connect(self.stop_live_polling)
        self.live_new_session_btn.clicked.connect(self.new_session)
        self.scan_btn.clicked.connect(lambda: self.spawn(self.do_scan()))
        self.readiness_btn.clicked.connect(lambda: self.spawn(self.do_readiness()))
        self.connect_btn.clicked.connect(lambda: self.spawn(self.do_connect()))
        self.disconnect_btn.clicked.connect(lambda: self.spawn(self.do_disconnect()))
        send.clicked.connect(lambda: self.spawn(self.do_send()))
        self.cmd.returnPressed.connect(lambda: self.spawn(self.do_send()))
        self.capture_btn.toggled.connect(self.toggle_capture)
        self.new_btn.clicked.connect(self.new_session); self.close_btn.clicked.connect(self.close_session); self.refresh_btn.clicked.connect(self.refresh_sessions)
        self.devices.currentIndexChanged.connect(self._refresh_ui_state)

        for key, kind in [(Qt.Key_1,'STOP'),(Qt.Key_2,'EV'),(Qt.Key_3,'ENGINE ON'),(Qt.Key_4,'ACCEL'),(Qt.Key_5,'CRUISE'),(Qt.Key_6,'REGEN')]:
            from PySide6.QtGui import QShortcut, QKeySequence
            q = QShortcut(QKeySequence(key), self); q.activated.connect(lambda k=kind: self.add_marker(k))

        self.timer = QTimer(self); self.timer.timeout.connect(self.pump); self.timer.start(10)
        self.loop = asyncio.new_event_loop()
        self.quality_timer = QTimer(self); self.quality_timer.timeout.connect(self.refresh_quality); self.quality_timer.start(2000)
        self.open_db(); self.new_session(); self.refresh_sessions(); self._refresh_ui_state()

    def open_db(self):
        root=Path.home()/'.honda-ehev-analyzer'; root.mkdir(parents=True,exist_ok=True)
        self.db=SessionDB(root/'sessions.sqlite3'); recovered=self.db.recover_open_sessions(); self.writer=AsyncSessionWriter(self.db.path)
        if recovered:self.status.setText('前回中断された記録を復旧しました：'+','.join(map(str,recovered)))

    def _flush_writer(self,timeout=5.0):
        if self.writer:self.writer.flush(timeout=timeout)

    def _persist(self,method,*args):
        if not self.writer:return
        try:
            getattr(self.writer,method)(*args)
            if method in ('append_raw','append_command','add_event','add_device'):
                self._mark_session_dirty()
        except Exception as e:
            self.live_polling=False; self.status.setText(f'保存エラーのため取得を停止しました：{type(e).__name__}: {e}'); self._refresh_ui_state()

    def _mark_session_dirty(self):
        if not self.session_dirty:
            self.session_dirty=True
            self._update_save_buttons()

    def _update_save_buttons(self):
        enabled=self.sid is not None and self.session_dirty
        if hasattr(self,'finish_btn'):self.finish_btn.setEnabled(enabled)
        if hasattr(self,'drive_finish_btn'):self.drive_finish_btn.setEnabled(enabled)
        if hasattr(self,'live_new_session_btn'):self.live_new_session_btn.setEnabled(self.sid is None and not self.live_polling)

    def _ui_action(self,action,detail=None):
        if self.sid and self.writer:
            try:self.writer.add_ui_action(self.sid,UTC(),str(action),None if detail is None else str(detail))
            except Exception:pass

    def _begin_connection_operation(self, name):
        name=str(name)
        if self.connection_gate.begin(name):
            self._ui_action('connection_operation_start',name)
            self._refresh_ui_state()
            return True
        active=self.connection_gate.current or '別の処理'
        self._ui_action('connection_operation_blocked',f'requested={name} active={active}')
        self.status.setText(f'接続・準備の「{active}」を実行中です。完了後にもう一度操作してください。')
        self._refresh_ui_state()
        return False

    def _end_connection_operation(self, name):
        if self.connection_gate.end(str(name)):
            self._ui_action('connection_operation_end',str(name))
        self._refresh_ui_state()

    def _refresh_ui_state(self, *_args):
        selected = self.devices.currentData() is not None
        connected = self.session is not None and self.transport is not None
        scan_running = self.did_discovery_task is not None and not self.did_discovery_task.done()
        connection_busy = self.connection_gate.busy
        self.scan_btn.setEnabled(not connected and not scan_running and not connection_busy)
        self.readiness_btn.setEnabled(selected and not connected and not scan_running and not connection_busy)
        self.connect_btn.setEnabled(selected and not connected and not scan_running and not connection_busy)
        self.disconnect_btn.setEnabled(connected and not connection_busy)
        can_start = connected and self.adapter_ready and not self.live_polling and self.sid is not None and not scan_running
        self.poll_start.setEnabled(can_start)
        self.poll_stop.setEnabled(self.live_polling)
        self.capture_btn.setEnabled(not self.live_polling and not scan_running)
        self.new_btn.setEnabled(not self.live_polling and not scan_running)
        self.close_btn.setEnabled(not self.live_polling and not scan_running and self.sid is not None)
        self._update_save_buttons()
        if not selected:
            self.connection_next.setText('次にすること：①「BLE機器を検索」を押し、一覧からKW905を選んでください。')
        elif not connected:
            if self.readiness_passed:
                self.connection_next.setText('実車準備テストはPASS済みです。次に③「KW905へ接続」を押してください。')
            else:
                self.connection_next.setText('次にすること：初回は②「実車準備テスト」を実行し、終了後に③「KW905へ接続」を押してください。')
        elif not self.adapter_ready:
            self.connection_next.setText('接続はしましたがELM初期化が完了していません。切断して再接続してください。')
        else:
            self.connection_next.setText('接続準備OKです。「2. ライブ表示」へ進み、ライブ取得を開始できます。')
        if self.live_polling:
            self.live_next.setText('ライブ取得中です。値が更新されていれば正常です。状態変化時はマーカーを押してください。')
        elif can_start:
            self.live_next.setText('準備OKです。「▶ ライブ取得を開始」を押してください。最初にRPM/車速/水温が表示されることを確認してください。')
        elif connected and self.adapter_ready and self.sid is None:
            self.live_next.setText('保存先の記録がありません。「次の記録を開始」を押してからライブ取得を開始してください。')
        elif not connected:
            self.live_next.setText('開始するには「1. 接続・準備」でKW905へ接続してください。')
        else:
            self.live_next.setText('ELM初期化が成功していないため開始できません。「1. 接続・準備」で再接続してください。')
        self.ecu_discovery.set_runtime_state(connected=connected, ready=self.adapter_ready, live_polling=self.live_polling, speed_kmh=self.last_vehicle_speed)
        for b in getattr(self,'drive_marker_buttons',[]): b.setEnabled(self.live_polling)
        for b in getattr(self,'live_marker_buttons',[]): b.setEnabled(self.live_polling)
        if hasattr(self,'drive_banner') and not self.live_polling and connected and self.adapter_ready:
            self.drive_banner.setText('先に「2. ライブ表示」でライブ取得を開始してください')
        sidtxt='なし' if self.sid is None else str(self.sid)
        if self.live_polling: next_html='<b>ライブ取得中です。必要なら「4. 走行記録」で助手席の人がマーカーを付けてください。</b>'
        elif connected and self.adapter_ready and self.sid is None: next_html='<b>保存済みです。次の取得は「2. ライブ表示」の「次の記録を開始」から始めてください。</b>'
        elif can_start: next_html='<b>次は「2. ライブ表示」で取得開始できます。</b>'
        else: next_html='<b>次は「1. 接続・準備」から進めてください。</b>'
        self.start_state.setText(
            f'<b>現在の状態</b><br>'
            f'・KW905接続：{"接続済み" if connected else "未接続"}<br>'
            f'・ELM初期化：{"OK" if self.adapter_ready else "未完了"}<br>'
            f'・ライブ取得：{"実行中" if self.live_polling else "停止中"}<br>'
            f'・保存先セッション：{sidtxt}<br><br>'+next_html
        )

    def new_session(self):
        if self.did_discovery_task is not None and not self.did_discovery_task.done():
            self.status.setText('DID探索中は記録を切り替えられません。先に探索を停止してください。'); return
        if self.sid:
            self._ui_action('new_session_requested','現在の記録を閉じて新しい記録を開始')
            self.close_session()
        self.sid=self.db.create_session(UTC(),git_commit=_git_commit(),tool_version=__version__)
        self.session_dirty=False
        self._ui_action('session_started',f'version={__version__} build={BUILD_ID}')
        self.analysis_sid=self.sid
        self.payload_analysis.set_source(f'現在のライブ記録（セッション {self.sid}）') if hasattr(self,'payload_analysis') else None
        self.session_t0=time.monotonic(); self.live_series={n:LiveSeriesBuffer() for n in ('Engine RPM','Vehicle Speed','Coolant','HV Battery SOC','HV Battery Voltage','HV Battery Current','HV Battery Power')}
        self.active_header=None; self.active_can_priority=None; self.last_analysis_range=None; self.last_vehicle_speed=None
        if hasattr(self,'live_plot'):self.live_plot.reset()
        self._range_stage='A'; self.status.setText(f'新しい記録 セッション {self.sid} を開始しました')
        self.refresh_sessions(); self._refresh_ui_state()

    def close_session(self):
        if self.did_discovery_task is not None and not self.did_discovery_task.done():
            self.status.setText('DID探索中は記録を閉じられません。先に探索を停止してください。'); return
        self._ui_action('session_close_requested')
        self.live_polling=False
        if self.poll_task and not self.poll_task.done():self.poll_task.cancel()
        self.poll_task=None
        if self.sid:
            sid=self.sid; self._flush_writer()
            if not self.db.discard_session_if_empty(sid):
                self.db.close_session(sid,UTC())
            self.sid=None; self.session_dirty=False; self.refresh_sessions()
        self._refresh_ui_state()

    def refresh_sessions(self):
        rows=self.db.list_sessions(); self.sessions.setRowCount(len(rows))
        for r,row in enumerate(rows):
            for c,val in enumerate(row):self.sessions.setItem(r,c,QTableWidgetItem('' if val is None else str(val)))
        if hasattr(self,'offline_replay'):self.offline_replay.refresh_sessions()
        if hasattr(self,'ecu_discovery'):self.ecu_discovery.refresh_sessions(rows,self.sid)

    def toggle_capture(self,on):
        self._ui_action('raw_capture_toggled',f'on={bool(on)}')
        self.capture_enabled=on; self.capture_btn.setText('RAW保存：ON（通常はONのまま）' if on else 'RAW保存：OFF（解析用の生データを保存しません）')

    def raw_observation(self,c):
        line=f'{c.timestamp.isoformat()} {c.source} {len(c.data)} {c.data.hex(" ").upper()}'; self.notify.appendPlainText(line)
        if self.capture_enabled and self.sid:self._persist('append_raw',self.sid,c.timestamp.isoformat(),'BLE',c.source,c.data)

    def add_marker(self,kind):
        if not self.live_polling:
            self.status.setText('マーカーはライブ取得中だけ保存できます。先に「2. ライブ表示」でライブ取得を開始してください。')
            return
        if not self.sid:
            self.status.setText('保存先の記録がありません。「記録管理」で新しい記録を開始してください。')
            return
        note=None
        if kind=='CUSTOM':
            note,ok=QInputDialog.getText(self,'その他のマーカー','あとで分かる短いメモを入力してください')
            if not ok:
                self.status.setText('「その他」マーカーの追加をキャンセルしました。')
                return
        self._ui_action('marker_added',f'{kind}: {note or ""}')
        self._persist('add_event',self.sid,UTC(),kind,note); self.live_plot.add_marker(time.monotonic()-self.session_t0,kind)
        jp={'STOP':'停止','EV':'EV','ENGINE ON':'エンジンON','ACCEL':'加速','CRUISE':'定速','REGEN':'回生','CUSTOM':'その他'}.get(kind,kind)
        self.status.setText(f'マーカーを保存しました：{jp}'); self.drive_last.setText(f'最後のマーカー：{jp}')

    def spawn(self,coro):self.loop.create_task(coro)

    async def _select_can_header(self, header: str):
        if self.active_header == header:return
        target_priority,_=split_29bit_header(header)
        for hcmd in elm327_header_commands(header,self.active_can_priority):
            hr=await self.session.command(hcmd,timeout=5.0); self.record_response(hcmd,hr)
            if not hr.success:raise RuntimeError(f'CAN Header {header} の設定に失敗しました（{hcmd}: {hr.text.strip()}）')
            if hcmd.startswith('ATCP'):self.active_can_priority=target_priority
        self.active_header=header

    def start_live_polling(self):
        self._ui_action('live_start_pressed')
        if not self.sid:
            self.status.setText('保存先の記録がありません。「次の記録を開始」を押してください。'); self._refresh_ui_state(); return
        if not self.session or not self.adapter_ready:
            self.status.setText('ライブ取得を開始できません。「1. 接続・準備」でKW905へ接続してください。'); self._refresh_ui_state(); return
        if self.live_polling:return
        if self.did_discovery_task is not None and not self.did_discovery_task.done():
            self.status.setText('DID探索中はライブ取得を開始できません。先に探索を停止してください。'); return
        self.live_polling=True; self.live_poll_errors=0; self.poll_scheduler=DueScheduler(); self.active_header=None; self.active_can_priority=None
        self.supported_mode01_pids=set(); self.state_pid_map={}; self.mode01_sweep=[]; self.mode01_sweep_index=0
        self.next_sweep_due=time.monotonic()+1.0; self.auto_state=AutoDriveStateTracker(); self.last_auto_state_label=None; self.pending_auto_state_label=None; self.pending_auto_state_since=None
        self.did_sweep_plan=list(self.db.positive_did_inventory()) if self.db else []
        self.did_sweep_index=0; self.did_sweep_samples=0; self.did_round_robin=PositiveDidRoundRobin(self.did_sweep_plan,exclude_dids={0x2012}); self.next_did_sweep_due=time.monotonic()+1.5
        created=UTC()
        # Snapshot the intended sweep atomically before driving.  Avoid enqueueing
        # thousands of plan rows ahead of time-critical RAW/command writes.
        self._flush_writer()
        self.db.save_did_drive_plan(self.sid,self.did_sweep_plan,created)
        self.auto_state_label.setText('判定準備中：標準OBD対応PIDを確認しています…')
        self.sweep_status.setText('標準PID巡回ダンプ：対応PIDを確認中…')
        self.did_sweep_status.setText(f'Positive DID巡回：予定 {len(self.did_sweep_plan)} DID。基準信号を優先し、空き時間で順番に取得します。')
        self.status.setText(f'ライブ取得を開始しました。標準OBD＋既知RAWに加え、保存済みPositive DID {len(self.did_sweep_plan)}件を走行中に巡回します。未知DIDの総当たり探索は走行中には行いません。')
        self.poll_task=self.loop.create_task(self.live_poll_loop()); self._refresh_ui_state()

    def stop_live_polling(self):
        self._ui_action('live_stop_pressed')
        self.live_polling=False; self.status.setText('ライブ取得を停止しました。保存済みデータは残っています。'); self._refresh_ui_state()

    async def _discover_mode01_support(self):
        """Read only Mode 01 support bitmaps and build the safe sweep list."""
        supported=set()
        await self._select_can_header('18DB33F1')
        for base in SUPPORT_BITMAP_PIDS:
            cmd=mode01_command(base)
            r=await self.session.command(cmd,timeout=5.0); self.record_response(cmd,r)
            if not r.success:
                break
            found=supported_pids_from_bitmap_response(r.text,base)
            supported.update(found)
            if not should_continue_bitmap(r.text,base):
                break
        self.supported_mode01_pids=supported
        self.state_pid_map=state_pid_choices(supported)
        state_specs=dynamic_state_specs(self.state_pid_map)
        self.poll_scheduler=DueScheduler(DEFAULT_POLLS+state_specs)
        # Sweep every supported current-data PID except bitmap queries and PIDs
        # already in the high-priority scheduler. RAW responses are preserved even
        # for PIDs we do not decode yet.
        high={sp.pid for sp in self.poll_scheduler.specs if sp.pid is not None}
        self.mode01_sweep=[pid for pid in sorted(supported) if pid not in SUPPORT_BITMAP_PIDS and pid not in high]
        choices=[]
        for role,pid in self.state_pid_map.items():
            if pid is not None:
                spec=STANDARD_PIDS.get(pid); choices.append(f'{role}=PID {pid:02X} {spec.name_ja if spec else ""}')
        self._ui_action('mode01_support_discovered',f'count={len(supported)} state={self.state_pid_map} sweep={len(self.mode01_sweep)}')
        self.sweep_status.setText(f'標準PID巡回ダンプ：対応 {len(supported)} PID、低速巡回 {len(self.mode01_sweep)} PID。' + (' / '.join(choices) if choices else ' 状態判定はRPM/車速中心です。'))

    def _update_auto_state_role(self,role,value,elapsed):
        nv=numeric_value(value)
        if nv is not None and role in ('rpm','speed','pedal','throttle','load','hv_power'):
            self.auto_state.update(role,nv,elapsed)
        result=self.auto_state.classify(elapsed)
        self.auto_state_label.setText(f'{result.label}　（判定信頼度：{result.confidence}）')
        self.auto_state_detail.setText(result.detail + '。HV電力が負で減速している場合は回生を実測確認しています。')
        # Event log is deliberately debounced.  The live label may react immediately,
        # but offline segmentation should not be flooded by 1 km/h quantization noise.
        if result.label == '判定待ち':
            return
        if result.label == self.last_auto_state_label:
            self.pending_auto_state_label=None; self.pending_auto_state_since=None
            return
        if self.pending_auto_state_label != result.label:
            self.pending_auto_state_label=result.label; self.pending_auto_state_since=float(elapsed)
            return
        if self.pending_auto_state_since is None or float(elapsed)-self.pending_auto_state_since < 1.2:
            return
        self.last_auto_state_label=result.label
        self.pending_auto_state_label=None; self.pending_auto_state_since=None
        if self.sid:
            self._persist('add_event',self.sid,UTC(),'AUTO_STATE',result.label+' | '+result.detail)
        self._ui_action('auto_state',result.label+' | '+result.detail)

    def _update_auto_state_from_poll(self,spec,value,elapsed):
        nv=numeric_value(value)
        if nv is None:return
        role=None
        if spec.pid==0x0C: role='rpm'
        elif spec.pid==0x0D: role='speed'
        else:
            for k,pid in self.state_pid_map.items():
                if pid==spec.pid: role=k; break
        if role:
            self._update_auto_state_role(role,nv,elapsed)

    async def _run_one_mode01_sweep(self):
        if not self.mode01_sweep:return
        pid=self.mode01_sweep[self.mode01_sweep_index % len(self.mode01_sweep)]
        self.mode01_sweep_index=(self.mode01_sweep_index+1)%len(self.mode01_sweep)
        await self._select_can_header('18DB33F1')
        cmd=mode01_command(pid)
        r=await self.session.command(cmd,timeout=5.0); self.record_response(cmd,r)
        if r.success:
            val=decode_standard_pid(pid,r.text)
            if val is not None:
                spec=STANDARD_PIDS.get(pid)
                self._ui_action('mode01_sweep_value',f'PID={pid:02X} {spec.name_ja if spec else ""} value={val}')

    async def _run_one_positive_did_sweep(self):
        if not self.did_sweep_plan:
            return
        # DID 2012 is already a core high-priority poll. It remains in the saved
        # plan, while the round-robin covers every other Positive DID fairly.
        item=self.did_round_robin.next()
        if item is None:return
        ecu,did,_initial,_rid,_disc_sid=item
        outcome=await self._request_uds22_with_compact_retry(ecu,int(did),timeout=5.0,context='did drive')
        if outcome.status in ('positive','positive_partial') and self.sid:
            partial=outcome.status=='positive_partial'
            self._persist('append_did_drive_sample',self.sid,UTC(),ecu,int(did),outcome.response_can_id,outcome.payload,outcome.latency_ms,True,partial)
            self.did_sweep_samples+=1
            suffix='（部分応答）' if partial else ''
            self.did_sweep_status.setText(f'Positive DID巡回：予定 {len(self.did_sweep_plan)} DID / 保存サンプル {self.did_sweep_samples} / 現在 ECU {ecu} DID {int(did):04X}{suffix}')
            if partial:self._ui_action('did_drive_partial',f'ecu={ecu} did={int(did):04X} bytes={len(outcome.payload)}')
        elif outcome.status in ('nrc','no_data','timeout'):
            self._ui_action('did_drive_unavailable',f'ecu={ecu} did={int(did):04X} status={outcome.status} nrc={outcome.nrc}')

    async def live_poll_loop(self):
        try:
            await self._discover_mode01_support()
        except Exception as e:
            # Do not lose the ride just because support discovery failed. Core
            # RPM/speed/Honda RAW polling can still proceed and all errors remain logged.
            self._ui_action('mode01_support_error',f'{type(e).__name__}: {e}')
            self.sweep_status.setText(f'標準PID巡回ダンプ：対応PID確認に失敗。基本項目の取得は継続します。({e})')
            self.poll_scheduler=DueScheduler(DEFAULT_POLLS)
        while self.live_polling and self.session:
            now=time.monotonic()
            # Low-rate sweeps run only when no high-priority item is due.
            # Choose whichever low-rate queue has waited longest so standard PID
            # coverage and Positive DID coverage both make progress.
            spec=self.poll_scheduler.due(now)
            if spec is None:
                due=[]
                if self.mode01_sweep and now>=self.next_sweep_due:due.append(('mode01',self.next_sweep_due))
                if self.did_sweep_plan and now>=self.next_did_sweep_due:due.append(('did',self.next_did_sweep_due))
                if due:
                    kind=min(due,key=lambda x:x[1])[0]
                    if kind=='mode01':
                        try:await self._run_one_mode01_sweep()
                        except Exception as e:self._ui_action('mode01_sweep_error',f'{type(e).__name__}: {e}')
                        self.next_sweep_due=time.monotonic()+self.mode01_sweep_interval_s
                    else:
                        try:await self._run_one_positive_did_sweep()
                        except Exception as e:self._ui_action('did_drive_sweep_error',f'{type(e).__name__}: {e}')
                        self.next_did_sweep_due=time.monotonic()+self.did_sweep_interval_s
                    continue
                await asyncio.sleep(.02); continue
            # Transport/protocol success and presentation/analysis success are deliberately
            # separated. A GUI/decoder bug must never turn an already-received RAW response
            # into a fake communication failure in the evidence database.
            try:
                await self._select_can_header(spec.header)
                r=await self.session.command(spec.command,timeout=5.0)
                self.record_response(spec.command,r)
                self.live_poll_errors=0
            except Exception as e:
                self.live_poll_errors+=1; msg=f'{type(e).__name__}: {e}'
                self._ui_action('live_poll_error',msg)
                self.status.setText(f'通信エラー（{self.live_poll_errors}回）：{msg}')
                self.term.appendPlainText(f'LIVE TRANSPORT ERROR: {msg}')
                if self.sid:self._persist('append_command',self.sid,UTC(),spec.command,msg.encode(),0.0,False)
                if 'CAN Header' in str(e) or self.live_poll_errors>=5:
                    self.live_polling=False; self.status.setText(f'ライブ取得を停止しました：{msg}'); self._refresh_ui_state()
                self.poll_scheduler.mark(spec)
                continue
            try:
                value=decode_poll(spec,r.text)
                self.live_decode_errors=0
                base_rows={'Engine RPM':0,'Vehicle Speed':1,'Coolant':2,'HV Battery SOC':3,'Hybrid/EV 019A':7,'UDS DID 2012':8}
                if spec.name in base_rows:
                    row=base_rows[spec.name]
                    if value is None:
                        shown='データなし'
                    elif spec.name=='HV Battery SOC':
                        shown=f'{float(value):.1f}'
                    elif spec.name in ('Engine RPM','Vehicle Speed','Coolant'):
                        shown=f'{float(value):.0f}'
                    else:
                        shown=str(value)
                    self.dashboard.setItem(row,1,QTableWidgetItem(shown))
                nv=numeric_value(value)
                elapsed=time.monotonic()-self.session_t0
                if spec.name=='Vehicle Speed' and nv is not None:self.last_vehicle_speed=nv; self._refresh_ui_state()
                if nv is not None and spec.name in self.live_series:
                    self.live_series[spec.name].append(elapsed,nv)
                    if spec.name in ('Engine RPM','Vehicle Speed','Coolant'):
                        x,y=self.live_series[spec.name].arrays(); self.live_plot.update_series(spec.name,x,y)
                if spec.command=='019A':
                    hev=decode_hybrid_ev_9a(r.text)
                    if hev is not None:
                        derived=(('HV Battery Voltage',hev.voltage_v,4,'V'),('HV Battery Current',hev.current_a,5,'A'),('HV Battery Power',hev.power_kw,6,'kW'))
                        for name,dv,row,_unit in derived:
                            if dv is None: continue
                            self.dashboard.setItem(row,1,QTableWidgetItem(f'{dv:.2f}'))
                            buf=self.live_series.get(name)
                            if buf is None:
                                buf=LiveSeriesBuffer(); self.live_series[name]=buf
                            buf.append(elapsed,float(dv))
                        if hev.power_kw is not None:
                            self._update_auto_state_role('hv_power',hev.power_kw,elapsed)
                if spec.command=='222012':
                    cand=decode_did2012_candidates(r.text)
                    hit=find_uds_22_payload(r.text,0x2012)
                    if hit and self.sid:
                        pld,rid=hit; ecu=response_ecu_from_29bit(rid or '')
                        if ecu:self._persist('append_did_drive_sample',self.sid,UTC(),ecu,0x2012,rid,pld,r.latency_ms,True)
                    if cand is not None and cand.soc_percent_candidate is not None:
                        self.dashboard.setItem(9,1,QTableWidgetItem(f'{cand.soc_percent_candidate:.0f}（候補）'))
                self._update_auto_state_from_poll(spec,value,elapsed)
            except Exception as e:
                self.live_decode_errors+=1; msg=f'{type(e).__name__}: {e}'
                self._ui_action('live_decode_error',f'command={spec.command} {msg}')
                self.status.setText(f'RAW受信は成功しましたが、表示/解析でエラーが発生しました：{msg}')
                self.term.appendPlainText(f'LIVE DECODE/UI ERROR (RAW SAVED): {spec.command}: {msg}')
            finally:
                self.poll_scheduler.mark(spec)

    def pump(self):self.loop.call_soon(self.loop.stop); self.loop.run_forever()

    def use_offline_analysis_session(self,sid):
        self._ui_action('offline_session_loaded',f'session={sid}')
        self.analysis_sid=int(sid); self._range_stage='A'; self.last_analysis_range=None
        self.payload_analysis.clear_ranges(); self.payload_analysis.set_source(f'保存済みセッション {sid}')
        self.status.setText(f'解析対象を保存済みセッション {sid} にしました')

    def capture_analysis_range(self,a,b,source='live'):
        # 範囲を動かしただけではA/Bへ自動確定しない。初心者が意図せず比較条件を
        # 上書きしないよう、Payload Analysisの明示ボタンでのみA/Bへ割り当てる。
        # また、ライブとオフラインの時間軸を混ぜないよう、選択元に解析対象を合わせる。
        new_sid=self.analysis_sid
        if source=='live' and self.sid is not None:
            new_sid=self.sid
        elif source=='offline' and self.offline_replay.sessions.currentData() is not None:
            new_sid=int(self.offline_replay.sessions.currentData())
        if new_sid != self.analysis_sid:
            self.analysis_sid=new_sid; self.payload_analysis.clear_ranges(); self.last_analysis_range=None
        if source=='live' and self.sid is not None:
            self.payload_analysis.set_source(f'現在のライブ記録（セッション {self.sid}）')
        elif source=='offline' and new_sid is not None:
            self.payload_analysis.set_source(f'保存済みセッション {new_sid}')
        self.last_analysis_range=(float(a),float(b)); self.payload_analysis.set_current_selection(a,b)

    def assign_payload_range(self,which):
        self._ui_action('payload_range_assign',f'which={which} range={self.last_analysis_range}')
        if not self.last_analysis_range:
            self.payload_analysis.set_error('まだ時間範囲が選択されていません。「5. 記録を見る」のグラフ上で選択帯を動かしてください。'); return
        a,b=self.last_analysis_range
        if which=='A':self.payload_analysis.set_a(a,b)
        else:self.payload_analysis.set_b(a,b)

    def _analysis_command(self,label):return '019A' if label=='019A' else '222012'

    def run_payload_analysis(self,label,a0,a1,b0,b1):
        self._ui_action('payload_analysis',f'{label} A={a0:.2f}-{a1:.2f} B={b0:.2f}-{b1:.2f}')
        target_sid=self.analysis_sid or self.sid
        if not target_sid:
            self.payload_analysis.set_error('解析する記録が選ばれていません。「5. 記録を見る」でセッションを読み込んでください。'); return
        self._flush_writer(); command=self._analysis_command(label); rows=self.db.command_rows(target_sid); started=self.db.session_started(target_sid)
        if not started:
            self.payload_analysis.set_error(f'セッション {target_sid} の開始時刻がありません。'); return
        sa=command_payloads(rows,command,started,a0,a1); sb=command_payloads(rows,command,started,b0,b1)
        combined=sorted(sa+sb,key=lambda x:x.elapsed_s); diffs=differential(sa,sb); act=activity(combined); _,_,matrix=heatmap_data(combined); fields=expanded_candidates(combined)
        self._payload_samples=combined
        self.payload_analysis.show_result(diffs,act,matrix,fields,counts=(len(sa),len(sb)),session_id=target_sid,command=command)
        self._ui_action('payload_analysis_result',f'session={target_sid} command={command} A={len(sa)} B={len(sb)}'); self.status.setText(f'データ比較：セッション {target_sid} / {command} / A={len(sa)}件 B={len(sb)}件')

    def filter_expanded_fields(self,offset):
        samples=getattr(self,'_payload_samples',[]); fields=expanded_candidates(samples,offset)
        self.payload_analysis._show_fields(fields); self.correlation_analysis.set_field_options(offset,fields)

    def run_field_correlation(self,reference_name):
        self._ui_action('correlation_analysis',f'reference={reference_name}')
        samples=getattr(self,'_payload_samples',[]); offset=self.correlation_analysis.offset; interpretation=self.correlation_analysis.current_field()
        if not samples or offset is None or not interpretation:
            self.correlation_analysis.set_error('先に「6. データ比較」で変化したbyte行をクリックしてください。'); return
        mapping={'Vehicle Speed':'Vehicle Speed','Engine RPM':'Engine RPM','Coolant':'Coolant','HV Battery SOC':'HV Battery SOC','HV Battery Power':'HV Battery Power'}
        key=mapping.get(reference_name)
        if key is None:
            self.correlation_analysis.set_error(f'比較対象 {reference_name} は未対応です。'); return
        if self.analysis_sid is not None and self.analysis_sid!=self.sid:
            ref=self.offline_replay.numeric_series(key); speed=self.offline_replay.numeric_series('Vehicle Speed'); engine=self.offline_replay.numeric_series('Engine RPM')
        else:
            refbuf=self.live_series.get(key); ref=[] if refbuf is None else [(x.t,x.value) for x in refbuf.samples]
            speed=[(x.t,x.value) for x in self.live_series['Vehicle Speed'].samples]; engine=[(x.t,x.value) for x in self.live_series['Engine RPM'].samples]
        r=analyze_field(samples,offset,interpretation,reference_name,ref,speed_series=speed,engine_series=engine)
        candidate=field_series(samples,offset,interpretation); _,y,x=align_nearest(candidate,ref,.75,r.best_lag_s or 0.0)
        self.correlation_analysis.show_result(r,x,y); self._ui_action('correlation_result',f'n={r.samples} field={interpretation} ref={reference_name}'); self.status.setText(f'相関解析：{interpretation} @ {offset} vs {reference_name} / n={r.samples}')

    def run_passive_ecu_census(self,sid):
        self._ui_action('ecu_passive_census',f'session={sid}')
        try:
            self._flush_writer(); rows=self.db.command_rows(int(sid)); census=passive_ecu_census(rows); inventory=diagnostic_response_inventory(rows)
            self.ecu_discovery.show_census(census,session_id=int(sid),source='保存済みデータ'); self.ecu_discovery.show_response_inventory(inventory)
            self.ecu_discovery.show_positive_dids(self.db.positive_did_inventory_detailed([e.ecu for e in census.entries]))
            self.status.setText(f'ECU確認：セッション {sid} から {census.responder_count} 個の応答ECU候補を確認')
        except Exception as e:
            self.ecu_discovery.summary.setText(f'解析できませんでした：{type(e).__name__}: {e}')

    def _stationary_probe_allowed(self):
        if not self.session or not self.adapter_ready:return False,'KW905が接続されていません。'
        if self.live_polling:return False,'ライブ取得を先に停止してください。'
        if not self.ecu_discovery.stationary.isChecked():return False,'完全停止・Pレンジ確認のチェックが必要です。'
        if self.last_vehicle_speed is not None and self.last_vehicle_speed>0.1:return False,f'車速が {self.last_vehicle_speed:.1f} km/h のため実行できません。'
        return True,''

    async def run_active_ecu_census(self):
        self._ui_action('ecu_active_census_pressed')
        ok,reason=self._stationary_probe_allowed()
        if not ok:self.ecu_discovery.summary.setText('実行できません：'+reason); self._refresh_ui_state(); return
        self.ecu_discovery.set_busy('停車中の安全なECU確認を実行中です。既知の読取り要求を1回ずつ送っています…')
        try:
            for name,cmd,header in SAFE_CENSUS_REQUESTS:
                self.status.setText(f'ECU確認中：{cmd}（{name}）')
                await self._select_can_header(header)
                r=await self.session.command(cmd,timeout=6.0); self.record_response(cmd,r)
                await asyncio.sleep(.05)
            self._flush_writer(); rows=self.db.command_rows(self.sid); census=passive_ecu_census(rows); inventory=diagnostic_response_inventory(rows)
            self.ecu_discovery.show_census(census,session_id=self.sid,source='停車中の安全な読取り'); self.ecu_discovery.show_response_inventory(inventory)
            self.status.setText(f'ECU確認完了：{census.responder_count} 個の応答ECU候補を確認しました')
        except Exception as e:
            self.ecu_discovery.summary.setText(f'ECU確認を中止しました：{type(e).__name__}: {e}')
            self.status.setText('ECU確認を中止しました。保存済みRAWは残っています。')
        finally:self._refresh_ui_state()

    async def run_stationary_probe(self,ecu):
        self._ui_action('ecu_stationary_probe',f'ecu={ecu}')
        ok,reason=self._stationary_probe_allowed()
        if not ok:self.ecu_discovery.show_probe_result(reason,ok=False); self._refresh_ui_state(); return
        request_id=physical_request_id_for_ecu(ecu); expected=expected_response_id_for_ecu(ecu)
        self.ecu_discovery.show_probe_result(f'ECU {ecu} へ確認中… request={request_id}')
        try:
            await self._select_can_header(request_id)
            r=await self.session.command('222012',timeout=7.0); self.record_response('222012',r)
            hit=find_uds_22_payload(r.text,0x2012)
            if hit:
                payload,response_id=hit
                match='' if response_id==expected else f'（想定応答ID {expected} とは異なります）'
                self.ecu_discovery.show_probe_result(f'ECU {ecu} が DID 2012 に応答しました。response={response_id} data={payload.hex(" ").upper()} {match}',ok=True)
                if self.sid:self._persist('save_scan_result',self.sid,ecu,0x2012,'positive',UTC(),r.latency_ms,None,payload,response_id)
            else:
                compact=' '.join(r.text.strip().split())[:240]
                self.ecu_discovery.show_probe_result(f'ECU {ecu} から 62 20 12 のpositive responseは確認できませんでした。RAW: {compact}',ok=False)
            self._flush_writer(); self.run_passive_ecu_census(self.sid)
        except Exception as e:
            self.ecu_discovery.show_probe_result(f'{type(e).__name__}: {e}',ok=False)
        finally:self._refresh_ui_state()

    def stop_did_discovery(self):
        self.did_discovery_stop=True
        self._ui_action('did_discovery_stop_requested')
        self.ecu_discovery.did_status.setText('停止要求を受け付けました。現在の1要求が終わったところで安全に停止します。')

    async def _scan_speed_check(self):
        await self._select_can_header('18DB33F1')
        r=await self.session.command('010D',timeout=5.0); self.record_response('010D',r)
        if not r.success:return None
        value=decode_standard_pid(0x0D,r.text)
        if value is not None:
            self.last_vehicle_speed=float(value); self._refresh_ui_state()
        return None if value is None else float(value)

    async def _set_did_scan_timing(self, rate_hz: float):
        profile=profile_for_rate(rate_hz)
        applied=[]
        for cmd in profile.setup_commands:
            r=await self.session.command(cmd,timeout=3.0); self.record_response(cmd,r)
            if not r.success:
                # Restore whatever may have been changed before falling back.
                for restore in profile.restore_commands:
                    try:
                        rr=await self.session.command(restore,timeout=3.0); self.record_response(restore,rr)
                    except Exception:
                        pass
                return profile,False,f'{cmd} が受理されませんでした。ELM通常タイミングのまま続行します。'
            applied.append(cmd)
        return profile,True,(profile.note if applied else 'ELM通常タイミングを使用します。')

    async def _restore_did_scan_timing(self, profile):
        for cmd in getattr(profile,'restore_commands',()):
            try:
                r=await self.session.command(cmd,timeout=3.0); self.record_response(cmd,r)
            except Exception as e:
                self._ui_action('did_scan_timing_restore_error',f'{cmd}: {type(e).__name__}: {e}')

    async def _request_uds22_with_compact_retry(self, ecu, did, *, timeout=5.0, context='did'):
        """Read one physical DID, recovering long BUFFER FULL responses when possible.

        The normal application uses ATH1 so response CAN IDs remain evidence.
        Some long RP8 DIDs overflow the KW905/ELM host-output buffer.  When a
        valid positive ISO-TP prefix is observed but the tail is truncated, retry
        once with ATH0 while CAF1/ATS0 remain enabled.  Official ELM behaviour
        formats that response more compactly.  If it is still too long, preserve
        the actually received prefix as ``positive_partial`` instead of losing the DID.
        """
        ecu=str(ecu).upper(); did=int(did); cmd=f'22{did:04X}'
        await self._select_can_header(physical_request_id_for_ecu(ecu))
        t=time.monotonic()
        try:
            r=await self.session.command(cmd,timeout=timeout)
        except asyncio.TimeoutError:
            if self.sid:self._persist('append_command',self.sid,UTC(),cmd,f'{context.upper()} TIMEOUT'.encode(),0.0,False)
            return DidProbeOutcome(ecu,did,'timeout',(time.monotonic()-t)*1000,raw_text='timeout')
        outcome=classify_uds_22_text(r.text,ecu,did,r.latency_ms)
        # BUFFER FULL after a proven 62 DID prefix is a data-truncation problem,
        # not a failed BLE/CAN request. Keep communication quality honest.
        self.record_response(cmd,r,success_override=True if outcome.status=='positive_partial' else None)
        if outcome.status!='positive_partial':
            return outcome

        self._ui_action('did_long_response',f'context={context} ecu={ecu} did={did:04X} partial={len(outcome.payload)}; compact retry')
        best=outcome
        header_off=False
        try:
            h0=await self.session.command('ATH0',timeout=3.0); self.record_response('ATH0',h0)
            header_off=bool(h0.success)
            if not header_off:
                return best
            r2=await self.session.command(cmd,timeout=max(timeout,7.0))
            out2=classify_uds_22_text(r2.text,ecu,did,r2.latency_ms)
            self.record_response(cmd,r2,success_override=True if out2.status in ('positive','positive_partial') else None)
            if out2.status=='positive':
                self._ui_action('did_compact_recovered',f'context={context} ecu={ecu} did={did:04X} bytes={len(out2.payload)}')
                return out2
            if out2.status=='positive_partial' and len(out2.payload)>len(best.payload):
                best=out2
            return best
        except asyncio.TimeoutError:
            self._ui_action('did_compact_timeout',f'context={context} ecu={ecu} did={did:04X}')
            return best
        except Exception as e:
            self._ui_action('did_compact_error',f'context={context} ecu={ecu} did={did:04X} {type(e).__name__}: {e}')
            return best
        finally:
            if header_off:
                try:
                    h1=await self.session.command('ATH1',timeout=3.0); self.record_response('ATH1',h1)
                except Exception as e:
                    self._ui_action('did_header_restore_error',f'{type(e).__name__}: {e}')
            # Do not assume any display/header state after the fallback.
            self.active_header=None; self.active_can_priority=None

    async def run_did_discovery(self,cfg):
        self._ui_action('did_discovery_start',str(cfg))
        ok,reason=self._stationary_probe_allowed()
        if not ok:
            self.ecu_discovery.did_status.setText('実行できません：'+reason); return
        if self.did_discovery_task and not self.did_discovery_task.done():
            self.ecu_discovery.did_status.setText('DID探索はすでに実行中です。'); return
        if not self.sid:
            self.ecu_discovery.did_status.setText('保存先セッションがありません。'); return
        ecus=[str(x).upper() for x in cfg.get('ecus',[])]
        start=int(cfg.get('start',0)); end=int(cfg.get('end',0xFFFF)); rate=float(cfg.get('rate_hz',2.0))
        completed={e:self.db.completed_dids_global(e,start,end) for e in ecus}
        positive_rows=self.db.positive_did_inventory(ecus)
        positive_hints={e:set() for e in ecus}
        for row in positive_rows:
            try: positive_hints[str(row[0]).upper()].add(int(row[1]))
            except Exception: pass
        already=sum(len(x) for x in completed.values()); total=len(ecus)*(end-start+1)
        self.did_discovery_stop=False; self.ecu_discovery.set_did_scan_busy(True,f'探索準備中：{total-already:,} DIDが未確認です。実車の車速を確認し、高速タイミングを設定します。')
        self.did_discovery_task=asyncio.current_task()
        timing_profile=None
        try:
            timing_profile,timing_ok,timing_note=await self._set_did_scan_timing(rate)
            self._ui_action('did_scan_timing',f'{timing_profile.name} target={rate:g}Hz ok={timing_ok} {timing_note}')
            self.ecu_discovery.did_status.setText(f'探索開始：目標 {rate:g} req/s / ELM {timing_profile.name}設定。{timing_note}')
        except Exception as e:
            timing_profile=profile_for_rate(rate)
            self._ui_action('did_scan_timing_error',f'{type(e).__name__}: {e}')
            self.ecu_discovery.did_status.setText(f'高速タイミング設定でエラーが出たため通常設定で探索します：{type(e).__name__}: {e}')

        async def probe(ecu,did):
            return await self._request_uds22_with_compact_retry(ecu,did,timeout=5.0,context='did discovery')

        def persist(outcome):
            if not self.sid:return
            self._persist('save_scan_result',self.sid,outcome.ecu,outcome.did,outcome.status,UTC(),outcome.latency_ms,outcome.nrc,outcome.payload,outcome.response_can_id)
            self._mark_session_dirty()

        def progress(p):
            self.ecu_discovery.set_did_scan_progress(p)

        engine=AsyncDidDiscovery(probe,self._scan_speed_check,persist,stop_requested=lambda:self.did_discovery_stop,on_progress=progress)
        try:
            rows=await engine.run(
                ecus,start,end,rate_hz=rate,completed_by_ecu=completed,
                positive_hints_by_ecu=positive_hints,speed_check_interval_s=2.0,
                adaptive_priority=True,
            )
            self._flush_writer()
            positives=self.db.positive_did_inventory(ecus); self.ecu_discovery.show_positive_dids(self.db.positive_did_inventory_detailed(ecus))
            stopped_speed=next((x for x in rows if x.status=='stopped_speed'),None)
            consecutive_error=len(rows) >= 5 and all(x.status=='error' for x in rows[-5:])
            if stopped_speed:
                stop_reason='speed_safety'; stop_detail=stopped_speed.raw_text
                self.ecu_discovery.did_status.setText('安全停止：車速が0 km/hと確認できなくなったためDID探索を停止しました。保存済み結果は残っています。')
            elif self.did_discovery_stop:
                stop_reason='user'; stop_detail='manual stop requested'
                self.ecu_discovery.did_status.setText(f'探索を停止しました。Positive DIDは現在 {len(positives)}件。次回「開始 / 続きから再開」で確認済みDIDを飛ばして続けられます。')
            elif consecutive_error:
                stop_reason='consecutive_error'; stop_detail='five consecutive infrastructure errors'
                self.ecu_discovery.did_status.setText('安全停止：通信/ヘッダ設定エラーが5回連続したため、同じ失敗を大量送信しないよう探索を止めました。ログを確認してから再開してください。')
            else:
                stop_reason='complete'; stop_detail='requested range completed'
                self.ecu_discovery.did_status.setText(f'指定範囲の探索が終了しました。保存済みPositive DID：{len(positives)}件。')
            self._ui_action('did_discovery_end',f'rows={len(rows)} positives={len(positives)} stop_reason={stop_reason} detail={stop_detail}')
        except Exception as e:
            self.ecu_discovery.did_status.setText(f'DID探索を中止しました：{type(e).__name__}: {e}。取得済み結果は保存されています。')
            self._ui_action('did_discovery_error',f'{type(e).__name__}: {e}')
        finally:
            if timing_profile is not None:
                await self._restore_did_scan_timing(timing_profile)
            # Header/timing state changed during discovery. Force the next live request
            # to configure its header explicitly.
            self.active_header=None; self.active_can_priority=None
            self.did_discovery_task=None; self.ecu_discovery.set_did_scan_busy(False); self._refresh_ui_state()

    def _known_drive_reference_series(self,sid):
        from datetime import datetime
        out={'speed':[],'rpm':[],'soc':[],'power':[],'current':[]}
        for ts,cmd,raw,_lat,success in self.db.command_rows(int(sid)):
            if not success:continue
            try:t=datetime.fromisoformat(str(ts).replace('Z','+00:00')).timestamp()
            except Exception:continue
            text=bytes(raw or b'').decode('ascii','replace'); key=''.join(str(cmd).upper().split())
            try:
                if key=='010D':v=decode_standard_pid(0x0D,text); name='speed'
                elif key=='010C':v=decode_standard_pid(0x0C,text); name='rpm'
                elif key=='015B':v=decode_standard_pid(0x5B,text); name='soc'
                elif key=='019A':
                    h=decode_hybrid_ev_9a(text)
                    if h is not None:
                        if h.power_kw is not None:out['power'].append((t,float(h.power_kw)))
                        if h.current_a is not None:out['current'].append((t,float(h.current_a)))
                    continue
                else:continue
                if v is not None:out[name].append((t,float(v)))
            except Exception:continue
        return out

    async def run_did_drive_analysis(self,sid):
        self._ui_action('did_drive_analysis',f'session={sid}')
        try:
            self.ecu_discovery.coverage_label.setText('DID走行データを解析中です。件数が多い場合でも画面を固めないようバックグラウンドで計算します…')
            self._flush_writer(); sid=int(sid)
            plan=self.db.did_drive_plan(sid); coverage=self.db.did_drive_coverage(sid); rows=self.db.did_drive_rows(sid)
            refs=self._known_drive_reference_series(sid)
            ranking=await asyncio.to_thread(rank_did_fields,rows,speed=refs['speed'],engine_rpm=refs['rpm'],hv_power=refs['power'],hv_current=refs['current'],soc=refs['soc'],top_n=120)
            self.ecu_discovery.show_did_analysis(coverage,ranking,len(plan))
            strong=max((x.priority_score for x in ranking),default=0.0)
            suffix=' 強い候補はまだありません。追加走行または別DID探索が必要です。' if strong<0.45 else ''
            self.status.setText(f'DID走行解析：予定 {len(plan)} DID / サンプル {len(rows)}件 / field候補 {len(ranking)}件。'+suffix)
        except Exception as e:
            self.ecu_discovery.coverage_label.setText(f'解析できませんでした：{type(e).__name__}: {e}')

    def refresh_quality(self):
        if not self.sid or not self.db:return
        try:
            q=live_quality_from_db(self.db,self.sid,self.current_rssi); self.last_quality=q
            p95=q.stats.get('p95_ms'); p95txt='未測定' if p95 is None else f'{p95:.0f} ms'
            grade={'GOOD':'良好','FAIR':'やや低下','POOR':'低下','NO DATA':'未測定'}.get(q.grade,q.grade)
            line=f'通信品質：{grade}  score={q.score}  p95={p95txt}  timeout={q.timeout_rate:.1%}  error={q.error_rate:.1%}'
            self.quality.setText(line); self.drive_comm.setText(line)
            a=communication_alert(q.grade,q.timeout_rate,q.error_rate,p95)
            msgmap={
                'Waiting for communication samples':'通信データを待っています',
                'Communication degraded — preserve the session and avoid starting scans':'通信品質が低下しています。記録を保存し、新しい探索は開始しないでください',
                'Communication quality is reduced; continue logging':'通信品質が少し低下しています。記録は継続できます',
                'Logging normally':'正常に記録中です',
            }
            self.drive_banner.setText(msgmap.get(a.message,a.message))
            styles={'OK':'font-size: 28px; font-weight: 700;','INFO':'font-size: 28px; font-weight: 700;','WARN':'font-size: 28px; font-weight: 800; background: #806000;','ALERT':'font-size: 28px; font-weight: 800; background: #8B1A1A;'}
            self.drive_banner.setStyleSheet(styles[a.severity])
        except Exception as e:self.quality.setText(f'通信品質：取得できません（{e}）')

    def finish_and_bundle(self):
        if self.did_discovery_task is not None and not self.did_discovery_task.done():
            self.status.setText('DID探索中はZIP保存を開始できません。先に探索を停止し、現在の結果がDBへ保存されてから実行してください。'); return
        if not self.sid:
            self.status.setText('保存する記録がありません。新しい記録を開始してデータを取得してください。')
            self._refresh_ui_state(); return
        self._ui_action('finish_and_bundle_pressed')
        self.live_polling=False
        if self.poll_task and not self.poll_task.done():self.poll_task.cancel()
        self.poll_task=None
        sid=self.sid; self._flush_writer()
        if not self.db.session_has_evidence(sid):
            self.status.setText('この記録には車両データがまだありません。空のデバッグZIPは作成しません。先に接続・取得を行ってください。')
            self.session_dirty=False; self._refresh_ui_state(); return
        q=live_quality_from_db(self.db,sid,self.current_rssi)
        self.db.close_session(sid,UTC()); self.sid=None; self.session_dirty=False
        root=Path.home()/'.honda-ehev-analyzer'/'debug-bundles'; root.mkdir(parents=True,exist_ok=True)
        dest=root/f'session-{sid}-{datetime.now().strftime("%Y%m%d-%H%M%S")}.zip'
        try:
            create_session_debug_bundle(dest,self.db.path,sid,tool_version=__version__,quality=q)
            final_message=f'セッション {sid} を保存しました。デバッグ用ZIP：{dest}　次の取得を始める場合は「次の記録を開始」を押してください。'
        except Exception as e:
            final_message=f'セッション {sid} は保存しましたがZIP作成に失敗しました：{e}'
        self.refresh_sessions(); self.status.setText(final_message); self._refresh_ui_state()

    async def do_scan(self):
        op='BLE機器検索'
        if not self._begin_connection_operation(op):return
        self._ui_action('ble_scan_pressed')
        self.devices.clear(); self.status.setText('BLE機器を検索しています…'); self.connection_next.setText('検索中です。数秒後に一覧からKW905を選んでください。')
        try:
            self.scan_rssi={}
            for d in await scan_devices():
                self.devices.addItem(f'{d.name or "名前不明"}  {d.identifier}',d.identifier); self.scan_rssi[d.identifier]=d.rssi
            self._ui_action('ble_scan_result',f'count={self.devices.count()}'); self.status.setText(f'BLE機器を {self.devices.count()} 件見つけました')
        except Exception as e:
            self._ui_action('ble_scan_error',f'{type(e).__name__}: {e}'); self.status.setText(f'BLE検索エラー：{e}')
        finally:
            self._end_connection_operation(op)

    async def do_connect(self):
        did=self.devices.currentData()
        self._ui_action('connect_pressed',f'device={did}')
        if not did:self.status.setText('先にBLE機器を検索し、KW905を選択してください。'); return
        op='KW905接続'
        if not self._begin_connection_operation(op):return
        self.current_rssi=self.scan_rssi.get(did); self.last_vehicle_speed=None
        transport=KW905BleTransport(did,raw_hook=self.raw_observation)
        self.transport=transport; self.session=None; self.adapter_ready=False
        self.status.setText('KW905へ接続し、ELM327を初期化しています…')
        try:
            await transport.connect(); session=ElmSession(transport); self.session=session; self.gatt.clear(); services={}
            for ch in transport.gatt:
                p=services.setdefault(ch.service_uuid,QTreeWidgetItem(self.gatt,[ch.service_uuid,''])); QTreeWidgetItem(p,[ch.uuid,', '.join(ch.properties)])
            meta={'write_char':transport.write_char,'notify_char':transport.notify_char,'mtu_size':transport.mtu_size,'scan_rssi_dbm':self.current_rssi,'gatt':[{'service':ch.service_uuid,'uuid':ch.uuid,'properties':ch.properties} for ch in transport.gatt]}
            if self.sid:self._persist('add_device',self.sid,'BLE',did,meta)
            results=await initialize(session)
            for r in results:self.record_response(r.command,r)
            self.adapter_ready=all(r.success for r in results[:9]); self.active_header=None; self.active_can_priority=None
            if self.adapter_ready:self._ui_action('connect_result',f'OK mtu={transport.mtu_size}'); self.status.setText(f'KW905接続OK。ELM初期化OK。MTU={transport.mtu_size}。「2. ライブ表示」へ進めます。')
            else:self._ui_action('connect_result','ELM initialization failed'); self.status.setText('KW905には接続しましたがELM初期化に失敗しました。切断して再接続してください。')
        except Exception as e:
            self._ui_action('connect_error',f'{type(e).__name__}: {e}'); self.status.setText(f'接続失敗：{e}')
            try:await transport.disconnect()
            except Exception:pass
            if self.transport is transport:
                self.transport=None; self.session=None; self.adapter_ready=False
        finally:
            self._end_connection_operation(op)

    def record_response(self,command,r,success_override=None):
        self.term.appendPlainText(f'> {command}  [{r.latency_ms:.1f} ms]\n{r.text}')
        success=r.success if success_override is None else bool(success_override)
        if self.sid:self._persist('append_command',self.sid,UTC(),command,r.raw,r.latency_ms,success)

    async def do_send(self):
        self._ui_action('terminal_send_pressed',self.cmd.text().strip())
        if not self.session:self.status.setText('ELM端末を使うには先にKW905へ接続してください。'); return
        c=self.cmd.text().strip()
        if not c:return
        if self.safe_terminal.isChecked() and not is_read_only_vehicle_command(c):
            self.status.setText('安全モードが読取り以外のコマンドをブロックしました。通常は安全モードをOFFにしないでください。'); return
        try:
            r=await self.session.command(c); self.record_response(c,r); self.cmd.clear()
            # Advanced terminal may change adapter/header state. Force guided features
            # to re-select their known 29-bit header on the next vehicle request.
            self.active_header=None; self.active_can_priority=None
        except Exception as e:
            self.term.appendPlainText(f'ERROR {e}')
            if self.sid:self._persist('append_command',self.sid,UTC(),c,f'{type(e).__name__}: {e}'.encode(),0.0,False)

    async def do_readiness(self):
        did=self.devices.currentData()
        self._ui_action('readiness_pressed',f'device={did}')
        if not did:self.status.setText('先にBLE機器を検索し、KW905を選択してください。'); return
        op='実車準備テスト'
        if not self._begin_connection_operation(op):return
        if self.transport:
            try:await self.transport.disconnect()
            except Exception:pass
        self.current_rssi=self.scan_rssi.get(did)
        transport=KW905BleTransport(did,raw_hook=self.raw_observation); transport.scan_rssi_dbm=self.current_rssi
        self.transport=transport; self.session=None; self.adapter_ready=False; self.status.setText('実車準備テスト中です。読取りのみで、DID総当たりは行いません…'); self._refresh_ui_state()
        try:
            report=await run_vehicle_readiness(transport,db=self.writer,session_id=self.sid); self._mark_session_dirty(); self._flush_writer(); self._ui_action('readiness_result',f'overall={report.overall}')
            root=Path.home()/'.honda-ehev-analyzer'/'readiness'; root.mkdir(parents=True,exist_ok=True)
            stamp=datetime.now().strftime('%Y%m%d-%H%M%S'); jp=root/f'readiness-{stamp}.json'; hp=root/f'readiness-{stamp}.html'
            report.write_json(jp); report.write_html(hp)
            self.term.appendPlainText('\n=== VEHICLE READINESS ===')
            for chk in report.checks:self.term.appendPlainText(f'{chk.status:4} {chk.name}: {chk.detail}')
            self.term.appendPlainText(f'Report: {hp}')
            if report.overall=='PASS':
                self.readiness_passed=True
                self.status.setText(f'実車準備テスト：PASS。次に「③ KW905へ接続」を押してください。レポート：{hp}')
            elif report.overall=='WARN':self.status.setText(f'実車準備テスト：WARN。内容を保存しました。次に必要なら再確認してください。レポート：{hp}')
            else:self.status.setText(f'実車準備テスト：FAIL。ライブ取得は開始せず、上級者端末のログを確認してください。レポート：{hp}')
        except Exception as e:
            self._ui_action('readiness_error',f'{type(e).__name__}: {e}'); self.status.setText(f'実車準備テスト失敗：{type(e).__name__}: {e}')
        finally:
            if self.transport is transport:
                self.transport=None; self.session=None; self.adapter_ready=False
            self._end_connection_operation(op)

    async def do_disconnect(self):
        self._ui_action('disconnect_pressed')
        self.did_discovery_stop=True
        self.live_polling=False
        if self.poll_task and not self.poll_task.done():self.poll_task.cancel()
        self.poll_task=None
        if self.transport:
            try:await self.transport.disconnect()
            except Exception:pass
        self.transport=None; self.session=None; self.adapter_ready=False; self.active_header=None; self.active_can_priority=None; self.last_vehicle_speed=None
        self.status.setText('KW905を切断しました。保存済みデータは残っています。'); self._refresh_ui_state()

    def closeEvent(self,event):
        self.live_polling=False
        self.did_discovery_stop=True
        if self.poll_task and not self.poll_task.done():self.poll_task.cancel()
        self.poll_task=None
        try:self._flush_writer()
        except Exception:pass
        if self.sid:
            sid=self.sid
            if not self.db.discard_session_if_empty(sid):self.db.close_session(sid,UTC(),'CLOSED')
            self.sid=None
        if self.writer:
            try:self.writer.close()
            except Exception:pass
            self.writer=None
        if self.db:self.db.conn.close()
        event.accept()


def main():
    app=QApplication(sys.argv); app.setApplicationName('Honda e:HEV Analyzer')
    w=MainWindow(); w.show(); sys.exit(app.exec())


if __name__=='__main__':main()
