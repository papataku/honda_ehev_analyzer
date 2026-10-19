import SwiftUI
import Charts
import HondaAnalyzerCore

/// No manual PID selection is needed. A graph appears only once the actual
/// observed value (or unassigned raw payload) changes.
struct AutomaticSignalTrendsView: View {
    @ObservedObject var model: AnalyzerViewModel

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("自動検出した変化")
                    .font(.title2.bold())
                Spacer()
                Text("\(model.changingSignals.count)件表示")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Text("値が変化した信号を自動表示。標準PIDは実際の値、未同定DIDは前回と異なるRAWバイト数です。候補の意味は推定しません。")
                .font(.caption)
                .foregroundStyle(.secondary)
            if model.changingSignals.isEmpty {
                AnalyzerCard("変化を検出中", systemImage: "waveform.path") {
                    Text("取得が始まると、変化した項目のグラフがここに現れます。値が一定の項目は省略します。")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
            } else {
                LazyVGrid(columns: [GridItem(.adaptive(minimum: 290), spacing: 12)], spacing: 12) {
                    ForEach(model.changingSignals) { trend in
                        AnalyzerCard(trend.title, systemImage: "chart.xyaxis.line") {
                            VStack(alignment: .leading, spacing: 8) {
                                Text("\(trend.id) ・ 変化 \(trend.changeCount)回")
                                    .font(.caption.monospaced())
                                    .foregroundStyle(.secondary)
                                Chart {
                                    ForEach(trend.points) { point in
                                        LineMark(
                                            x: .value("時刻", point.date),
                                            y: .value(trend.unit, point.value)
                                        )
                                    }
                                }
                                .chartXAxis(.hidden)
                                .frame(height: 135)
                                Text(trend.isRawChange
                                     ? "RAW差分（前回から変更されたバイト数）。値の意味は未同定"
                                     : "数値（\(trend.unit)）の時系列")
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                        }
                    }
                }
            }
        }
    }
}
