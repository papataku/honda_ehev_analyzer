# Phase 27 — 初心者向け日本語UI + ECU確認

## 目的

実車ログ取得後のフィードバックを反映し、CAN/OBD/UDSを知らない人でも「この画面で何をするか」「何が分かるか」「先に何が必要か」を判断できるGUIへ整理した。

## 画面構成

推奨順序に合わせてタブを並べた。

1. はじめに
2. 接続・準備
3. ライブ表示
4. ECU確認
5. 走行記録
6. 記録を見る
7. データ比較
8. 相関を見る
9. 記録管理
10. 上級者：ELM327端末

各ページ上部に次の3項目を常時表示する。

- ここですること
- ここで分かること
- 先に必要なこと

条件不足時は単にボタンを無効化するだけでなく、次に必要な操作を日本語で表示する。

## ECU確認

### A. 保存済みデータからECU候補を確認

車両への送信は行わない。保存済み `commands.raw_response` から `18DAF1xx` 形式のresponse CAN IDを抽出し、source byte `xx` ごとに集計する。

重要: 表示する数は **今回の診断要求に応答したECU候補数** であり、車両搭載ECU総数ではない。

### B. 停車中の安全なECU確認

以下の既知read-only requestだけを各1回送る。

- 0100
- 010C
- 010D
- 0105
- 019A
- 222012

DID範囲スキャン、書込みサービス、Security Access、Routine Control等は実行しない。

実行条件:

- KW905接続済み
- ELM初期化済み
- Live Polling停止済み
- 「完全停止・Pレンジ」チェック済み
- 既知の最新車速が0より大きい場合は実行不可

### C. 選択ECUへのDID 2012単発Probe

観測済みsource `xx` を標準29-bit physical request `18DAxxF1` に変換し、UDS `22 2012` を1回だけ送信する。

例:

- response `18DAF101` -> ECU source `01`
- physical request `18DA01F1`
- expected response `18DAF101`

これはDID scanではない。

## 実車ログを反映した回帰条件

実車で観測された形式を回帰テストへ入れている。

- 010C responder: `18DAF1EF`, `18DAF10E`, `18DAF101`, `18DAF102`, `18DAF106`
- 019A: `18DAF101` multi-frame
- 222012: `18DAF101` multi-frame
- classic ELM327 29-bit header: `ATCP18` + 6-hex-digit `ATSH`

ISO-TP multi-frameは1つのELM command response内で同じECUを重複カウントしない。

## UI上の誤操作防止

- Live Polling開始条件を画面表示
- 走行記録マーカーボタンはLive Polling前は無効
- ECU active queryは停車条件未確認時は無効
- Payload A/Bは範囲を動かしただけでは自動確定しない
- CorrelationはPayload offset選択前に実行できない理由を表示
- ELM端末は最後の「上級者」タブへ移動し、安全モードを初期ON

## 既知の制約

- ECU候補一覧は診断応答者のcensusであり、車両ネットワーク全体のECU enumerationではない。
- ECUの役割名（PCM/BCM等）はresponse IDだけから推測しない。
- DID 2012の意味は未確定のまま。
- DID範囲スキャナcoreは存在するが、この初心者向け画面からは開始しない。
