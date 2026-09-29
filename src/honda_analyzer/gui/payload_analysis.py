from __future__ import annotations
from PySide6.QtCore import Signal
from PySide6.QtWidgets import QWidget,QVBoxLayout,QHBoxLayout,QGridLayout,QPushButton,QComboBox,QLabel,QTableWidget,QTableWidgetItem,QHeaderView,QGroupBox
import pyqtgraph as pg
import numpy as np
from honda_analyzer.gui.guide_widgets import guide_box
from honda_analyzer.gui.page_guides import PAGE_GUIDES


class PayloadAnalysisWidget(QWidget):
    requestAnalysis=Signal(str,float,float,float,float)
    fieldSelected=Signal(int)
    assignRange=Signal(str)
    def __init__(self,parent=None):
        super().__init__(parent); self.a=None;self.b=None;self.current_selection=None
        v=QVBoxLayout(self); v.addWidget(guide_box(PAGE_GUIDES['payload']))
        self.source=QLabel('解析対象：現在のライブ記録');self.source.setWordWrap(True);v.addWidget(self.source)
        steps=QLabel('<b>使い方：</b> ①「5. 記録を見る」で記録を読み込む → ② グラフの選択帯を比較したいA区間へ動かす → ③ Aに設定 → ④ 別のB区間を選ぶ → ⑤ Bに設定 → ⑥ 比較する')
        steps.setWordWrap(True);steps.setStyleSheet('padding: 8px; background: rgba(80,120,180,0.10);');v.addWidget(steps)
        self.info=QLabel('まだA/B区間が決まっていません。Aは「基準状態」、Bは「比べたい状態」と考えてください。例：A=停止、B=EV走行。')
        self.info.setWordWrap(True);v.addWidget(self.info)
        top=QGridLayout(); top.addWidget(QLabel('比較するRAW：'),0,0);self.command=QComboBox();self.command.addItem('PID 9A RAW（構造既知・検算用）','019A');self.command.addItem('DID 2012 RAW（意味未確定）','222012'); top.addWidget(self.command,0,1)
        self.set_a_btn=QPushButton('現在の選択範囲を A（基準）にする');self.set_b_btn=QPushButton('現在の選択範囲を B（比較対象）にする');run=QPushButton('A と B を比較する')
        self.run_btn=run
        self.set_a_btn.clicked.connect(lambda:self.assignRange.emit('A'));self.set_b_btn.clicked.connect(lambda:self.assignRange.emit('B'));run.clicked.connect(self._run)
        self.set_a_btn.setEnabled(False);self.set_b_btn.setEnabled(False);self.run_btn.setEnabled(False)
        top.addWidget(self.set_a_btn,1,0); top.addWidget(self.set_b_btn,1,1); top.addWidget(run,2,0,1,2)
        top.setColumnStretch(0,1); top.setColumnStretch(1,1)
        v.addLayout(top)
        self.ranges=QLabel('A（基準）：未設定    B（比較対象）：未設定');self.ranges.setWordWrap(True);v.addWidget(self.ranges)
        self.diff=QTableWidget(0,8);self.diff.setHorizontalHeaderLabels(['Byte位置','A中央値','A範囲','B中央値','B範囲','中央値差','区間内変化 A/B','分布差']);self.diff.horizontalHeader().setSectionResizeMode(QHeaderView.ResizeToContents);self.diff.cellClicked.connect(self._select);v.addWidget(self.diff)
        stathelp=QLabel('比較は1つの代表payloadではなく、各Byteの統計で行います。分布差は0.00=ほぼ同じ、1.00=観測値の分布が重ならない、という目安です。値が違っても意味の確定ではありません。');stathelp.setWordWrap(True);v.addWidget(stathelp)
        heat_group=QGroupBox('Byteの変化ヒートマップ（横=Byte位置、縦=サンプル）');hv=QVBoxLayout(heat_group)
        self.heat=pg.PlotWidget();self.heat.setLabel('left','サンプル');self.heat.setLabel('bottom','Byte位置');self.image=pg.ImageItem();self.heat.addItem(self.image);hv.addWidget(self.heat);v.addWidget(heat_group)
        fhelp=QLabel('上の比較表でByte位置をクリックすると、その位置を u8 / s8 / u16 など複数の読み方に展開します。ここで表示される値は「候補」であり意味の確定ではありません。');fhelp.setWordWrap(True);v.addWidget(fhelp)
        self.fields=QTableWidget(0,3);self.fields.setHorizontalHeaderLabels(['Byte位置','読み方の候補','値']);self.fields.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch);v.addWidget(self.fields)
    def set_source(self,text):self.source.setText('解析対象：'+str(text))
    def clear_ranges(self):
        self.a=None;self.b=None;self.current_selection=None;self.set_a_btn.setEnabled(False);self.set_b_btn.setEnabled(False);self.run_btn.setEnabled(False);self._refresh_ranges();self.info.setText('A/B区間を選び直してください。まず「5. 記録を見る」のグラフで基準にしたい時間帯を選びます。')
    def _refresh_ranges(self):
        af='未設定' if self.a is None else f'{self.a[0]:.2f}～{self.a[1]:.2f}秒'
        bf='未設定' if self.b is None else f'{self.b[0]:.2f}～{self.b[1]:.2f}秒'
        cf='' if self.current_selection is None else f'    現在の選択：{self.current_selection[0]:.2f}～{self.current_selection[1]:.2f}秒'
        self.ranges.setText(f'A（基準）：{af}    B（比較対象）：{bf}{cf}')
    def set_current_selection(self,a,b):
        self.current_selection=(float(a),float(b));self.set_a_btn.setEnabled(True);self.set_b_btn.setEnabled(True);self._refresh_ranges();self.info.setText('時間範囲を選択しました。基準にしたいなら「Aにする」、比較したいなら「Bにする」を押してください。')
    def set_a(self,a,b):self.a=(float(a),float(b));self.run_btn.setEnabled(self.b is not None);self._refresh_ranges();self.info.setText('A（基準）を設定しました。次にグラフで別の時間帯を選び、B（比較対象）を設定してください。')
    def set_b(self,a,b):self.b=(float(a),float(b));self.run_btn.setEnabled(self.a is not None);self._refresh_ranges();self.info.setText('A/Bの両方を設定しました。PID 9AまたはDID 2012を選び、「A と B を比較する」を押してください。')
    def set_error(self,text):self.info.setText('実行できません：'+str(text))
    def _run(self):
        if not self.a or not self.b:
            self.set_error('AとBの両方が必要です。「5. 記録を見る」で時間範囲を選び、このページのA/B設定ボタンを使ってください。')
            return
        self.requestAnalysis.emit(self.command.currentData(),self.a[0],self.a[1],self.b[0],self.b[1])
    def show_result(self,diffs,activity,matrix,fields,counts=None,session_id=None,command=None):
        self.diff.setRowCount(len(diffs))
        def med(v):
            if v is None:return '--'
            return f'{v:.1f} (0x{int(round(v)):02X})'
        def rng(lo,hi):
            if lo is None or hi is None:return '--'
            return f'{lo}–{hi} (0x{lo:02X}–0x{hi:02X})'
        for r,d in enumerate(diffs):
            delta='--' if d.a_median is None or d.b_median is None else f'{d.b_median-d.a_median:+.1f}'
            vals=[d.offset,med(d.a_median),rng(d.a_min,d.a_max),med(d.b_median),rng(d.b_min,d.b_max),delta,f'{d.a_change_ratio:.2f} / {d.b_change_ratio:.2f}',f'{d.distribution_distance:.2f}']
            for c,x in enumerate(vals):self.diff.setItem(r,c,QTableWidgetItem(str(x)))
        if matrix:
            arr=np.array(matrix,dtype=float);arr[arr<0]=np.nan;self.image.setImage(arr.T,autoLevels=True);self.heat.setYRange(0,max(1,arr.shape[0]));self.heat.setXRange(0,max(1,arr.shape[1]))
        else:self.image.clear()
        self._show_fields(fields)
        if counts is not None:
            a,b=counts;prefix=f'セッション {session_id} / {command}：' if session_id is not None else ''
            if a==0 or b==0:self.set_error(f'{prefix}選んだ時間帯のサンプル数が A={a}、B={b} です。両方の区間にこのコマンドの成功応答が必要です。別の時間範囲を選んでください。')
            else:self.info.setText(f'{prefix}比較完了。A={a}件、B={b}件。分布差や中央値差が大きいByteをクリックすると読み方候補を展開できます。')
    def _show_fields(self,fields):
        self.fields.setRowCount(len(fields))
        for r,(off,name,val) in enumerate(fields):
            for c,x in enumerate((off,name,val)):self.fields.setItem(r,c,QTableWidgetItem(str(x)))
    def _select(self,row,col):
        it=self.diff.item(row,0)
        if it:self.fieldSelected.emit(int(it.text()))
