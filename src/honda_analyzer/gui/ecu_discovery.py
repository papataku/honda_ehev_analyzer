from __future__ import annotations

from PySide6.QtCore import Signal
from PySide6.QtWidgets import (
    QWidget, QVBoxLayout, QLabel, QPushButton, QComboBox, QTableWidget,
    QTableWidgetItem, QHeaderView, QCheckBox, QGroupBox, QGridLayout,
    QSizePolicy, QLineEdit, QProgressBar,
)

from honda_analyzer.analysis.ecu_census import SAFE_CENSUS_REQUESTS
from honda_analyzer.analysis.did_discovery import estimate_scan_seconds
from honda_analyzer.gui.guide_widgets import guide_box
from honda_analyzer.gui.page_guides import PAGE_GUIDES


def _fmt_duration(seconds: float) -> str:
    seconds=max(0,int(seconds))
    h,rem=divmod(seconds,3600); m,s=divmod(rem,60)
    if h:return f'約 {h}時間{m:02d}分'
    if m:return f'約 {m}分{s:02d}秒'
    return f'約 {s}秒'


class EcuDiscoveryWidget(QWidget):
    requestPassive = Signal(int)
    requestActive = Signal()
    requestProbe = Signal(str)
    requestDidScan = Signal(object)
    requestDidStop = Signal()
    requestDidAnalysis = Signal(int)

    def __init__(self, parent=None):
        super().__init__(parent)
        self._connected=False; self._ready=False; self._live_polling=False; self._speed=None
        self._selected_ecu=None; self._scan_busy=False

        v=QVBoxLayout(self)
        v.addWidget(guide_box(PAGE_GUIDES['ecu']))
        warning=QLabel(
            '<b>大切：</b>ここで表示する「ECU候補数」は、診断要求に応答した数です。'
            '車に搭載されているECU総数ではありません。DID探索は読取り専用UDS 0x22だけを使用しますが、'
            '長時間になるため必ず安全な場所で停車・Pレンジのまま実行してください。'
        )
        warning.setWordWrap(True); warning.setStyleSheet('padding:8px;background:rgba(220,170,30,0.14);'); v.addWidget(warning)

        offline=QGroupBox('A. 保存済みデータからECU候補を確認（車への送信なし）')
        ov=QVBoxLayout(offline)
        oh=QGridLayout(); oh.addWidget(QLabel('解析する記録：'),0,0)
        self.sessions=QComboBox(); self.sessions.setSizePolicy(QSizePolicy.Expanding,QSizePolicy.Fixed)
        self.passive_btn=QPushButton('保存済みデータからECU候補を確認')
        oh.addWidget(self.sessions,0,1); oh.addWidget(self.passive_btn,1,0,1,2); oh.setColumnStretch(1,1); ov.addLayout(oh); v.addWidget(offline)

        active=QGroupBox('B. 停車中の安全なECU確認（既知要求だけ）')
        av=QVBoxLayout(active)
        ahelp=QLabel('既知の読取り要求を1回ずつ送ります：'+' / '.join(f'{cmd} ({name})' for name,cmd,_ in SAFE_CENSUS_REQUESTS)+'。ここではDID範囲探索はしません。')
        ahelp.setWordWrap(True); av.addWidget(ahelp)
        self.stationary=QCheckBox('車が安全な場所で完全停止・Pレンジであることを確認しました')
        self.active_btn=QPushButton('停車中の安全なECU確認を実行')
        self.active_reason=QLabel('先にKW905接続と停車確認が必要です。'); self.active_reason.setWordWrap(True)
        av.addWidget(self.stationary); av.addWidget(self.active_btn); av.addWidget(self.active_reason); v.addWidget(active)

        result=QGroupBox('C. 今回見えたECU候補と診断応答')
        rv=QVBoxLayout(result)
        self.summary=QLabel('まだ解析していません。まずAのボタンを押してください。'); self.summary.setWordWrap(True); rv.addWidget(self.summary)
        self.ecus=QTableWidget(0,5); self.ecus.setHorizontalHeaderLabels(['ECU識別値 (source)','応答CAN ID','応答した診断要求数','応答した要求','意味'])
        self.ecus.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); self.ecus.horizontalHeader().setStretchLastSection(True); self.ecus.cellClicked.connect(self._select_ecu); rv.addWidget(self.ecus)
        self.matrix=QTableWidget(0,0); rv.addWidget(self.matrix)
        invhelp=QLabel('走行後は、応答CAN ID × 要求ごとにサンプル数・異なるpayload数・変化Byte数を確認できます。これはアプリが送った診断要求への応答であり、車内CAN全フレームではありません。')
        invhelp.setWordWrap(True); rv.addWidget(invhelp)
        self.inventory=QTableWidget(0,6); self.inventory.setHorizontalHeaderLabels(['応答CAN ID','要求','サンプル数','異なるpayload数','payload長','変化したByte数']); self.inventory.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); rv.addWidget(self.inventory)
        v.addWidget(result)

        probe=QGroupBox('D. 選択したECUを1台だけ確認（任意）')
        pv=QVBoxLayout(probe)
        phelp=QLabel('選択したECU候補へ、読取り専用のUDS 22 2012を1回だけ物理アドレスで送ります。役割や意味を確定する操作ではありません。')
        phelp.setWordWrap(True); pv.addWidget(phelp)
        self.probe_btn=QPushButton('選択したECUへ DID 2012 を1回だけ確認')
        self.probe_result=QLabel('ECU候補の行をクリックすると選択できます。'); self.probe_result.setWordWrap(True)
        pv.addWidget(self.probe_btn); pv.addWidget(self.probe_result); v.addWidget(probe)

        scan=QGroupBox('E. 停車中：UDS DID探索（Positive DID一覧を作る）')
        sv=QVBoxLayout(scan)
        intro=QLabel(
            '<b>何をする？</b> Cで見つかったECUへ <code>22 XXXX</code> を順番に送り、データを返したDIDを保存します。'
            '<br><b>何が分かる？</b> 走行中に読む候補DIDの一覧が作れます。値の意味はこの段階では分かりません。'
            '<br><b>注意：</b> 0000〜FFFFを5 ECU・10 req/sで全探索すると理論上約9.1時間です。実効速度はKW905/ECUの応答時間で下がる場合があります。複数日に分けて停止/再開できます。'
            '既にPositive、部分Positive（長すぎて末尾が欠けた応答）、またはNRC 0x31で確認済みのDIDは次回自動で飛ばします。timeout/NO DATAは再試行します。'
            '<br><b>探索範囲の意味：</b> 現在の診断セッションのまま読めるUDS 0x22だけを探索します。診断セッション変更(0x10)、Security Access(0x27)、書込みサービスは使用しません。'
            'そのため、特別なセッションや解除が必要なDIDはこの探索では見つかりません。<br>'
            '<b>探索順：</b>①既知の2000〜20FF帯 → ②0000/1000/…/F000の16領域を短く確認 → '
            '③各0x100ページの先頭と中央を代表確認 → ④反応したページを優先して全確認 → ⑤最後に未探索DIDを全て埋めます。<br>'
            '代表点で反応が無くても、その領域を「空」と決めつけて省略はしません。最終的な探索範囲は変わりません。<br>'
            '<b>長い応答：</b>KW905がBUFFER FULLを返した場合は自動でヘッダ非表示のcompact再取得を試します。なお長すぎる場合は受信できた先頭部分を「部分Positive」として保存し、DID自体を取りこぼしません。'
        )
        intro.setWordWrap(True); sv.addWidget(intro)
        grid=QGridLayout()
        grid.addWidget(QLabel('対象ECU：'),0,0); self.scan_target=QComboBox(); self.scan_target.addItem('表示中のECU候補をすべて','ALL'); grid.addWidget(self.scan_target,0,1,1,2)
        grid.addWidget(QLabel('開始DID (16進)：'),1,0); self.scan_start=QLineEdit('0000'); self.scan_start.setMaxLength(4); grid.addWidget(self.scan_start,1,1)
        grid.addWidget(QLabel('終了DID (16進)：'),1,2); self.scan_end=QLineEdit('FFFF'); self.scan_end.setMaxLength(4); grid.addWidget(self.scan_end,1,3)
        grid.addWidget(QLabel('探索速度：'),2,0); self.scan_rate=QComboBox();
        for label,val in [('2 req/s（標準）',2.0),('5 req/s（中速）',5.0),('8 req/s（高速）',8.0),('10 req/s（推奨・目標値）',10.0)]:self.scan_rate.addItem(label,val)
        self.scan_rate.setCurrentIndex(3); grid.addWidget(self.scan_rate,2,1,1,3)
        grid.setColumnStretch(1,1); grid.setColumnStretch(3,1); sv.addLayout(grid)
        self.scan_estimate=QLabel('推定時間は対象ECUと範囲から計算します。'); self.scan_estimate.setWordWrap(True); sv.addWidget(self.scan_estimate)
        self.long_scan_ack=QCheckBox('長時間探索になる場合でも、停車状態を維持して途中保存・再開しながら実行することを理解しました')
        self.long_scan_ack.toggled.connect(self._refresh_actions); sv.addWidget(self.long_scan_ack)
        self.did_start_btn=QPushButton('DID探索を開始 / 続きから再開')
        self.did_stop_btn=QPushButton('探索を安全に停止'); self.did_stop_btn.setEnabled(False)
        bg=QGridLayout(); bg.addWidget(self.did_start_btn,0,0); bg.addWidget(self.did_stop_btn,0,1); sv.addLayout(bg)
        self.did_progress=QProgressBar(); self.did_progress.setRange(0,1000); self.did_progress.setValue(0); sv.addWidget(self.did_progress)
        self.did_status=QLabel('未開始。まずECU候補を表示し、完全停止・Pレンジ確認にチェックしてください。'); self.did_status.setWordWrap(True); sv.addWidget(self.did_status)
        self.positive_table=QTableWidget(0,7); self.positive_table.setHorizontalHeaderLabels(['ECU','DID','取得状態','response CAN ID','payload長','最終payload','発見セッション']); self.positive_table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); self.positive_table.horizontalHeader().setStretchLastSection(True); sv.addWidget(self.positive_table)
        v.addWidget(scan)

        drive=QGroupBox('F. 走行後：Positive DID巡回のCoverageと候補ランキング')
        dv=QVBoxLayout(drive)
        dhex=QLabel(
            'DID探索でpositiveだったDIDは、次回「ライブ取得」を開始すると自動で走行中ラウンドロビン取得します。'
            'RPM/車速/HV電力などを優先し、空き時間にPositive DIDを1個ずつ読むため、DID数が多いほど各DIDの周期は長くなります。'
            'ここでは「予定したDIDのうち何件取れたか」と、EV区間の車速・HV電力・SOC等との相関候補を確認できます。'
        )
        dhex.setWordWrap(True); dv.addWidget(dhex)
        self.drive_analysis_btn=QPushButton('選択中セッションのDID走行データを解析')
        dv.addWidget(self.drive_analysis_btn)
        self.coverage_label=QLabel('まだ解析していません。'); self.coverage_label.setWordWrap(True); dv.addWidget(self.coverage_label)
        self.coverage_table=QTableWidget(0,7); self.coverage_table.setHorizontalHeaderLabels(['ECU','DID','取得サンプル数','異なるpayload数','最小長','最大長','部分応答数']); self.coverage_table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); dv.addWidget(self.coverage_table)
        self.rank_table=QTableWidget(0,12); self.rank_table.setHorizontalHeaderLabels(['ECU','DID','field','samples','変化率','EV車速相関','全車速相関','HV電力相関','HV電流相関','SOC相関','優先度','候補メモ']); self.rank_table.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents); self.rank_table.horizontalHeader().setStretchLastSection(True); dv.addWidget(self.rank_table)
        v.addWidget(drive)

        self.passive_btn.clicked.connect(self._passive)
        self.active_btn.clicked.connect(self.requestActive.emit)
        self.probe_btn.clicked.connect(self._probe)
        self.did_start_btn.clicked.connect(self._did_scan)
        self.did_stop_btn.clicked.connect(self.requestDidStop.emit)
        self.drive_analysis_btn.clicked.connect(self._did_analysis)
        self.stationary.toggled.connect(self._refresh_actions)
        for w in (self.scan_start,self.scan_end):w.textChanged.connect(self._refresh_actions)
        self.scan_rate.currentIndexChanged.connect(self._refresh_actions)
        self.scan_target.currentIndexChanged.connect(self._refresh_actions)
        self._refresh_actions()

    def refresh_sessions(self, rows, current_sid=None):
        old=self.sessions.currentData(); self.sessions.blockSignals(True); self.sessions.clear()
        for row in rows:
            sid,started,ended,status,*_=row; marker='現在' if current_sid is not None and int(sid)==int(current_sid) else status
            self.sessions.addItem(f'セッション {sid}  {started}  [{marker}]',int(sid))
        target=current_sid if current_sid is not None else old
        if target is not None:
            for i in range(self.sessions.count()):
                if self.sessions.itemData(i)==int(target):self.sessions.setCurrentIndex(i);break
        self.sessions.blockSignals(False); self.passive_btn.setEnabled(self.sessions.count()>0); self.drive_analysis_btn.setEnabled(self.sessions.count()>0)

    def selected_session_id(self):
        v=self.sessions.currentData(); return None if v is None else int(v)

    def current_ecus(self):
        out=[]
        for r in range(self.ecus.rowCount()):
            it=self.ecus.item(r,0)
            if it and it.text().strip():out.append(it.text().strip().upper())
        return out

    def set_runtime_state(self, *, connected: bool, ready: bool, live_polling: bool, speed_kmh=None):
        self._connected=bool(connected); self._ready=bool(ready); self._live_polling=bool(live_polling); self._speed=speed_kmh; self._refresh_actions()

    def _refresh_actions(self):
        reasons=[]
        if not self._connected:reasons.append('KW905が未接続です')
        elif not self._ready:reasons.append('ELM初期化が完了していません')
        if self._live_polling:reasons.append('ライブ取得を先に停止してください')
        if not self.stationary.isChecked():reasons.append('「完全停止・Pレンジ」を確認してチェックしてください')
        if self._speed is not None and float(self._speed)>0.1:reasons.append(f'現在の車速が {float(self._speed):.1f} km/h のため実行できません')
        ok=not reasons
        self.active_btn.setEnabled(ok and not self._scan_busy)
        self.probe_btn.setEnabled(ok and self._selected_ecu is not None and not self._scan_busy)
        rng=self._parse_range(); ecu_count=len(self.current_ecus()) if self.scan_target.currentData()=='ALL' else (1 if self._selected_ecu else 0)
        long_scan=bool(rng and ecu_count and ecu_count*(rng[1]-rng[0]+1)>4096)
        self.did_start_btn.setEnabled(ok and bool(self.current_ecus()) and not self._scan_busy and (not long_scan or self.long_scan_ack.isChecked()))
        self.did_stop_btn.setEnabled(self._scan_busy)
        self.active_reason.setText('実行できます。' if ok else '実行するには：'+' / '.join(reasons))
        self._update_estimate()

    def _parse_range(self):
        try:
            start=int(self.scan_start.text().strip(),16); end=int(self.scan_end.text().strip(),16)
            if not 0<=start<=end<=0xFFFF:raise ValueError
            return start,end
        except Exception:return None

    def _update_estimate(self):
        rng=self._parse_range(); ecus=self.current_ecus(); rate=float(self.scan_rate.currentData() or 1.0)
        if not rng or not ecus:
            self.scan_estimate.setText('ECU候補と有効な16進DID範囲を指定すると推定時間を表示します。'); return
        start,end=rng; count=len(ecus) if self.scan_target.currentData()=='ALL' else 1
        sec=estimate_scan_seconds(count,start,end,rate)
        self.scan_estimate.setText(f'理論上の最大：{count} ECU × {end-start+1:,} DID = {count*(end-start+1):,}要求、目標 {rate:g} req/sで {_fmt_duration(sec)}。実効速度はKW905/ECUの応答時間が上限です。既に確認済みのDIDは飛ばします。' + (' 長時間探索の確認チェックが必要です。' if count*(end-start+1)>4096 else ''))

    def _passive(self):
        sid=self.selected_session_id()
        if sid is not None:self.requestPassive.emit(sid)

    def _select_ecu(self,row,_col):
        item=self.ecus.item(row,0); self._selected_ecu=item.text() if item else None
        if self._selected_ecu:self.probe_result.setText(f'選択中：ECU識別値 {self._selected_ecu}。これはECU名称ではありません。')
        # Keep a single-ECU scan target option in sync with the selected row.
        while self.scan_target.count()>1:self.scan_target.removeItem(1)
        if self._selected_ecu:self.scan_target.addItem(f'選択中ECU {self._selected_ecu} だけ',self._selected_ecu)
        self._refresh_actions()

    def _probe(self):
        if self._selected_ecu:self.requestProbe.emit(self._selected_ecu)

    def _did_scan(self):
        rng=self._parse_range()
        if not rng:
            self.did_status.setText('開始/終了DIDは0000〜FFFFの4桁16進数で入力してください。'); return
        target=self.scan_target.currentData(); ecus=self.current_ecus() if target=='ALL' else [str(target)]
        if not ecus:
            self.did_status.setText('先にAまたはBでECU候補を表示してください。'); return
        self.requestDidScan.emit({'ecus':ecus,'start':rng[0],'end':rng[1],'rate_hz':float(self.scan_rate.currentData() or 1.0)})

    def _did_analysis(self):
        sid=self.selected_session_id()
        if sid is not None:self.requestDidAnalysis.emit(sid)

    def set_busy(self,text):
        self.summary.setText(str(text)); self.active_btn.setEnabled(False); self.probe_btn.setEnabled(False)

    def set_did_scan_busy(self,busy:bool,text=None):
        self._scan_busy=bool(busy)
        if text:self.did_status.setText(str(text))
        self._refresh_actions()

    def set_did_scan_progress(self,p):
        self.did_progress.setValue(max(0,min(1000,int(p.percent*10))))
        self.did_status.setText(f'探索中 [{getattr(p,"phase","探索")}]：ECU {p.ecu} / DID {p.did:04X} / {p.completed:,}/{p.total:,} ({p.percent:.2f}%) / 実効 {p.achieved_hz:.1f} req/s / 残り目安 {_fmt_duration(p.eta_s or 0)} / Positive {p.positive} / NRC31 {p.terminal_negative} / 再試行候補 {p.retryable} / 経過 {_fmt_duration(p.elapsed_s)}')

    def show_census(self,census,*,session_id=None,source='保存済みデータ'):
        self._selected_ecu=None; self.ecus.setRowCount(len(census.entries))
        for r,e in enumerate(census.entries):
            vals=(e.ecu,e.response_can_id,e.response_count,', '.join(e.commands),'診断要求に応答したECU候補（役割は未確定）')
            for c,val in enumerate(vals):self.ecus.setItem(r,c,QTableWidgetItem(str(val)))
        commands=[cmd for _name,cmd,_header in SAFE_CENSUS_REQUESTS]
        self.matrix.setRowCount(len(census.entries)); self.matrix.setColumnCount(1+len(commands)); self.matrix.setHorizontalHeaderLabels(['ECU']+commands)
        for r,e in enumerate(census.entries):
            self.matrix.setItem(r,0,QTableWidgetItem(e.ecu))
            for c,cmd in enumerate(commands,1):
                n=census.matrix.get((e.ecu,cmd),0); self.matrix.setItem(r,c,QTableWidgetItem('—' if n==0 else f'✓ ({n})'))
        self.matrix.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents)
        sidtxt='' if session_id is None else f'セッション {session_id} / '
        self.summary.setText((f'{sidtxt}{source}から <b>{census.responder_count} 個の応答ECU候補</b>を確認しました。これは搭載ECU総数ではありません。') if census.responder_count else f'{sidtxt}{source}には18DAF1xx形式の応答ECU候補がありませんでした。')
        self._refresh_actions()

    def show_response_inventory(self,entries):
        self.inventory.setRowCount(len(entries))
        for r,e in enumerate(entries):
            length=str(e.payload_length_min) if e.payload_length_min==e.payload_length_max else f'{e.payload_length_min}–{e.payload_length_max}'
            for c,val in enumerate((e.response_can_id,e.command,e.samples,e.unique_payloads,length,e.changing_byte_count)):self.inventory.setItem(r,c,QTableWidgetItem(str(val)))

    def show_probe_result(self,text,*,ok=None):
        prefix='確認結果：' if ok is None else ('確認成功：' if ok else '応答なし/未対応：'); self.probe_result.setText(prefix+str(text)); self._refresh_actions()

    def show_positive_dids(self,rows):
        self.positive_table.setRowCount(len(rows))
        partial_count=0
        for r,row in enumerate(rows):
            if len(row)>=6:
                ecu,did,status,payload,response_id,disc_sid=row[:6]
            else:
                ecu,did,payload,response_id,disc_sid=row[:5]; status='positive'
            partial=str(status)=='positive_partial'; partial_count+=int(partial)
            state='部分（末尾欠落）' if partial else '完全'
            vals=(ecu,f'{int(did):04X}',state,response_id or '—',len(payload or b''),(bytes(payload or b'')[:24].hex(' ').upper() + (' …' if len(payload or b'')>24 else '')),disc_sid)
            for c,val in enumerate(vals):self.positive_table.setItem(r,c,QTableWidgetItem(str(val)))
        extra=f' / うち部分応答 {partial_count}件' if partial_count else ''
        self.did_status.setText(f'保存済みPositive DID：{len(rows)}件{extra}。ライブ取得開始時にはこの一覧を走行巡回対象として固定保存します。')

    def show_did_analysis(self,coverage,ranking,planned_count:int):
        self.coverage_table.setRowCount(len(coverage)); got=sum(1 for x in coverage if x[2]>0)
        for r,row in enumerate(coverage):
            for c,val in enumerate(row):self.coverage_table.setItem(r,c,QTableWidgetItem(str(val if c!=1 else f'{int(val):04X}')))
        self.coverage_label.setText(f'巡回予定 {planned_count} DID / 実際に1回以上取得 {got} DID。0件のDIDは通信帯域や走行時間のため順番が回らなかった可能性があります。')
        self.rank_table.setRowCount(len(ranking))
        def f(v):return '—' if v is None else f'{v:+.3f}'
        for r,x in enumerate(ranking):
            vals=(x.ecu,f'{x.did:04X}',x.field,x.samples,f'{x.changing_ratio:.1%}',f(x.corr_speed_ev),f(x.corr_speed_all),f(x.corr_hv_power),f(x.corr_hv_current),f(x.corr_soc),f'{x.priority_score:.3f}',x.note)
            for c,val in enumerate(vals):self.rank_table.setItem(r,c,QTableWidgetItem(str(val)))
