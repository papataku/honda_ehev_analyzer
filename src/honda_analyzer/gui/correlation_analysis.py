from __future__ import annotations
from PySide6.QtCore import Signal
from PySide6.QtWidgets import QWidget,QVBoxLayout,QHBoxLayout,QGridLayout,QLabel,QComboBox,QPushButton,QTableWidget,QTableWidgetItem,QHeaderView
import pyqtgraph as pg
from honda_analyzer.gui.guide_widgets import guide_box
from honda_analyzer.gui.page_guides import PAGE_GUIDES


class CorrelationAnalysisWidget(QWidget):
    requestCorrelation=Signal(str)
    def __init__(self,parent=None):
        super().__init__(parent);self.offset=None;self.interpretations=[]
        v=QVBoxLayout(self);v.addWidget(guide_box(PAGE_GUIDES['correlation']))
        self.help=QLabel('まだfieldが選ばれていません。先に「6. データ比較」で変化したByte位置をクリックしてください。');self.help.setWordWrap(True);v.addWidget(self.help)
        h=QGridLayout();self.title=QLabel('選択field：未設定');self.title.setWordWrap(True);self.field=QComboBox();self.reference=QComboBox();self.reference.addItem('車速','Vehicle Speed');self.reference.addItem('エンジン回転数','Engine RPM');self.reference.addItem('冷却水温','Coolant');self.reference.addItem('HVバッテリーSOC','HV Battery SOC');self.reference.addItem('HVバッテリー電力','HV Battery Power');run=QPushButton('相関を計算する');self.run_btn=run;self.run_btn.setEnabled(False);run.clicked.connect(lambda:self.requestCorrelation.emit(self.reference.currentData()))
        h.addWidget(self.title,0,0,1,2); h.addWidget(QLabel('fieldの読み方：'),1,0); h.addWidget(self.field,1,1); h.addWidget(QLabel('比較する既知信号：'),2,0); h.addWidget(self.reference,2,1); h.addWidget(run,3,0,1,2); h.setColumnStretch(1,1)
        v.addLayout(h);self.result=QTableWidget(0,2);self.result.setHorizontalHeaderLabels(['指標','結果']);self.result.horizontalHeader().setSectionResizeMode(QHeaderView.Stretch);v.addWidget(self.result)
        self.scatter=pg.PlotWidget();self.scatter.setLabel('bottom','既知信号');self.scatter.setLabel('left','未知field');v.addWidget(self.scatter)
        self.notes=QLabel('<b>注意：</b>Pearson/SpearmanやCandidate Scoreが高くても、そのfieldの意味が確定したことにはなりません。実車条件を変えて再現性を確認し、CANDIDATE → VERIFIEDを人が判断します。');self.notes.setWordWrap(True);v.addWidget(self.notes)
    def set_field_options(self,offset,fields):
        self.offset=offset;self.field.clear();self.interpretations=[name for off,name,val in fields if off==offset]
        self.field.addItems(self.interpretations);self.run_btn.setEnabled(bool(self.interpretations));self.title.setText(f'選択field：Byte位置 {offset}');self.help.setText('読み方候補を選び、既知信号を選んで「相関を計算する」を押してください。')
    def current_field(self):return self.field.currentText()
    def set_error(self,text):self.help.setText('実行できません：'+str(text))
    def show_result(self,r,x,y):
        def f(v):return 'n/a' if v is None or (isinstance(v,float) and v!=v) else (f'{v:.4f}' if isinstance(v,float) else str(v))
        rows=[('fieldの読み方',r.interpretation),('比較対象',r.reference),('比較できたサンプル数',r.samples),('Pearson相関',r.pearson),('Spearman相関',r.spearman),('最も合う時間ずれ (秒)',r.best_lag_s),('時間ずれ補正後 r',r.best_lag_r),('Motor候補スコア',r.candidate_score),('候補を支持する要素','; '.join(r.evidence) or '—'),('矛盾する要素','; '.join(r.contradictions) or '—')]
        self.result.setRowCount(len(rows))
        for i,(k,val) in enumerate(rows):self.result.setItem(i,0,QTableWidgetItem(k));self.result.setItem(i,1,QTableWidgetItem(f(val)))
        self.scatter.clear();self.scatter.plot(x,y,pen=None,symbol='o',symbolSize=6)
        self.help.setText(f'計算完了：{r.samples} サンプルを比較しました。数値だけで確定せず、散布図と実車状態も確認してください。')
