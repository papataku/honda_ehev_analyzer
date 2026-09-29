# 0.2.7 Release Notes

実車Session 4のレビュー結果を反映したハードニング版。

## 修正

- Payload A/B比較を「最頻のpayload 1個」方式からByte単位の統計比較へ変更
  - 中央値
  - 平均
  - min/max
  - 区間内変化率
  - A/B分布差（total variation distance）
- field展開用の代表値もwhole-payload modeではなくByte単位中央値へ変更
- データが無いSessionではデバッグZIP作成を禁止
- 保存後に空Sessionを自動生成しない
- 空Sessionを閉じた場合は一覧から破棄
- 次の取得は明示的に「次の記録を開始」
- UI操作ログをSQLiteとdebug bundle (`ui_actions.jsonl`) に追加
- `.git`が無い配布ZIPでもBUILD_ID/SOURCE_HASHをmanifestとSession識別子へ保存
- ECU確認に「全診断応答インベントリ」を追加
  - response CAN ID
  - command
  - sample count
  - unique payload count
  - payload length
  - changing byte count
- 走行記録ページに「全CAN受動キャプチャではない」ことを明記

## 実車Session 4での確認

新しいresponse inventoryで以下を個別に復元できることを確認した。

- 18DAF101
- 18DAF102
- 18DAF106
- 18DAF10E
- 18DAF1EF

Session 4では、例として以下を確認。

- 18DAF101 / 010C: 134 samples
- 18DAF102 / 010C: 134 samples
- 18DAF106 / 010C: 134 samples
- 18DAF10E / 010C: 134 samples
- 18DAF1EF / 010C: 134 samples
- 18DAF101 / 019A: 133 samples, 101 unique payloads
- 18DAF101 / 222012: 48 samples, 48 unique payloads

この結果は「アプリが送った診断要求への応答」の解析であり、車内CAN全フレーム取得を意味しない。
