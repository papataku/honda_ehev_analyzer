from __future__ import annotations
from PySide6.QtCore import Signal
from PySide6.QtWidgets import QWidget,QVBoxLayout,QHBoxLayout,QLabel
import pyqtgraph as pg


class LivePlotWidget(QWidget):
    rangeSelected=Signal(float,float)
    def __init__(self,parent=None):
        super().__init__(parent); self._curves={}; self._markers=[]
        v=QVBoxLayout(self); h=QHBoxLayout(); self.info=QLabel('表示：直近最大5分。灰色の選択帯は後でA/B比較に使えます。'); h.addWidget(self.info);h.addStretch(1);v.addLayout(h)
        self.plot=pg.PlotWidget();self.plot.showGrid(x=True,y=True,alpha=.2);self.plot.setLabel('bottom','記録開始からの時間','秒');self.plot.addLegend();v.addWidget(self.plot)
        self.region=pg.LinearRegionItem(values=(0,10),movable=True);self.region.setVisible(False);self.plot.addItem(self.region);self.region.sigRegionChangeFinished.connect(self._selected)
    def set_signal_visible(self,name,visible):
        if name in self._curves:self._curves[name].setVisible(visible)
    def update_series(self,name,x,y):
        labels={'Engine RPM':'エンジン回転数','Vehicle Speed':'車速','Coolant':'冷却水温'}
        c=self._curves.get(name)
        if c is None:c=self.plot.plot(name=labels.get(name,name));self._curves[name]=c
        c.setData(x,y)
    def add_marker(self,t,label):
        labels={'STOP':'停止','EV':'EV','ENGINE ON':'エンジンON','ACCEL':'加速','CRUISE':'定速','REGEN':'回生','CUSTOM':'その他'}
        line=pg.InfiniteLine(pos=t,angle=90,movable=False,label=labels.get(label,label));self.plot.addItem(line);self._markers.append(line)
    def enable_selection(self,on=True):self.region.setVisible(on)
    def reset(self):
        for c in self._curves.values():c.setData([],[])
        for m in self._markers:
            try:self.plot.removeItem(m)
            except Exception:pass
        self._markers.clear();self.region.setRegion((0,10));self.info.setText('表示：直近最大5分。灰色の選択帯は後でA/B比較に使えます。')
    def _selected(self):
        a,b=self.region.getRegion();self.info.setText(f'現在の選択範囲：{a:.2f}～{b:.2f}秒（「6. データ比較」でA/Bに設定できます）');self.rangeSelected.emit(float(a),float(b))
