# 0.3.4 — Session 15 長大DID応答リカバリ

## 実車Session 15で判明した問題

ECU `01` の `0x2000–0x20FF`探索では、少なくとも17 DIDが `62 DID` のPositive responseを開始していた。
0.3.3が完全Positiveとして保存できたのは6 DIDのみで、11 DIDは長大応答の途中でKW905/ELMが `BUFFER FULL`を返したため `error`扱いになっていた。

完全取得できたDID:
`2001, 2010, 2012, 2013, 2018, 2020`

Positive開始を確認したが末尾が欠落したDID:
`2019, 2025, 2028, 202A, 202B, 202C, 2059, 2068, 206A, 206B, 206C`

## 修正

- 有効なISO-TP prefixが `62 DID` を証明していれば `BUFFER FULL`でも `positive_partial` として保存する。
- 受信済みpayload prefixを証拠として保持し、欠落Byteを推測・補完しない。
- `positive_partial`をDID存在確認済みとしてresume対象から除外し、同じ長大DIDの無限再試行を防止する。
- 長大応答時は `ATH0` へ一時切替してcompact再取得を1回試みる。完全取得できれば`positive`へ昇格する。
- compact再取得でも長すぎる場合は、より長い実受信prefixを保持した`positive_partial`のまま探索を続行する。
- compact retry終了後は `ATH1`へ復帰し、次要求ではCAN headerを必ず再設定する。
- `BUFFER FULL`付きでもPositive prefixが確認できた要求は、BLE/CAN通信失敗率へ算入しない。
- 走行DID sweepでも部分応答を保存し、Coverageへ「部分応答数」を表示する。
- Positive DID一覧へ「完全 / 部分（末尾欠落）」を表示する。
- Debug Bundleの`did_drive_samples.jsonl`へ`partial`フラグを保存する。
- Preflightへ長大DID responseのpartial/compact再構成セルフテストを追加する。

## 重要な制約

`ATH0` compact retryで全長246 byte級の応答が実機KW905で最後まで取得できるかは、次の実車停車テストで確認する。取得できなくてもDID自体と受信済みprefixは失わず、探索は次へ進む。
