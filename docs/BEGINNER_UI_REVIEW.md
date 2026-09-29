# 初心者UI 多段レビュー記録

0.2.4作成時に、同じ画面を複数の観点から繰り返しレビューした。

## Review 1 — 画面の目的が分かるか

問題: 旧UIはタブ名が機能名中心で、初めて見る人がどの順番で操作すべきか分からなかった。

修正:
- 「はじめに」を追加
- 推奨操作順にタブを並べ替え
- 全主要ページに「すること / 分かること / 先に必要なこと」を表示
- 上級者端末を最後へ移動

## Review 2 — 専門用語だけで操作を要求していないか

問題: Payload Analysis / Correlationの用語だけではA/Bやfieldの意味が分かりにくい。

修正:
- A=基準状態、B=比較対象と明記
- STOP vs EVのような例を追加
- Byte offset / field expansionが「候補」であることを表示
- Pearson/Spearmanを残しつつ、数値が高くてもVERIFIEDではないと明記

## Review 3 — 隠れた操作がないか

問題: グラフのrange変更だけでA/Bが自動交互設定され、意図せず比較条件が変わり得た。

修正:
- range移動は「現在選択」に限定
- A/Bへの確定は明示ボタンのみ
- サンプル0件時は理由と次の操作を表示

## Review 4 — 数字が誤解を生まないか

問題: ISO-TP multi-frameをframe単位で数えると、1回の応答を複数回と誤認する。

修正:
- 1 ELM command response内の同一response CAN IDは1応答として集計
- 「ECU候補数 = 搭載ECU総数ではない」をECU画面に常時表示
- ECU役割は推測せず「未確定」と表示

## Review 5 — 条件不足時に黙って失敗しないか

修正:
- Live開始ボタンの可否と理由を表示
- Drive markerはLive開始前は無効
- ECU active queryは接続/ELM/Live停止/停車確認/車速条件でgate
- Offline Replay未読込時の再生操作に案内
- Correlationの前提不足を日本語で表示
- 再接続時に古い車速値をリセット

## Review 6 — 実車で使う安全境界が明確か

- ECU census active requestは固定allow-listのみ
- physical probeは選択ECUに `22 2012` を1回だけ
- DID range scanはこのGUIから開始しない
- ELM terminalは安全モード初期ON
- Vehicle Readinessは従来通りread-only sequence

## 検証

- Core/analysis regression: pytest
- 実車形式compact 29-bit CAN response
- ISO-TP multi-frame census
- classic ELM327 `ATCP18 + ATSHxxxxxx`
- safe census allow-list
- physical `18DAxxF1` DID 2012 single probe
- Python compileall

この実行環境にはPySide6がないため、Qt画面の実レンダリング確認はApple Silicon Mac側で行う。UIロジックはPySide6非依存部分を分離して単体テストしている。
