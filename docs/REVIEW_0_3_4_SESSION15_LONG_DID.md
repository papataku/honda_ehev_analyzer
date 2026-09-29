# 0.3.4 Session 15 長大DIDレビュー

## 1. 車載通信レビュー

- Session 15では、`BUFFER FULL`の前に有効なFirst Frame/Consecutive Frameが連続し、application payload先頭が`62 DID`だった。
- したがって「DID未対応」や「CAN通信失敗」ではなく、ホスト出力側で末尾が欠けたPositive responseとして扱う。
- 欠落Byteを生成して完全payloadに見せない。
- CAN IDを保持できる通常`ATH1`を基本とし、長大応答だけ`ATH0`でcompact再取得する。

## 2. 探索アルゴリズムレビュー

- 0.3.3では長大DIDが`error`となり、resume時に未完了として先頭で再試行された。
- 同様のDIDが5件続くと安全停止条件に入り、探索がその先へ進めなかった。
- `positive_partial`はPositiveとして連続errorカウンタをresetし、resumeでは確認済み扱いとする。
- timeout / NO DATAは従来どおり再試行対象とする。

## 3. 証拠保全レビュー

- 完全/部分をDB statusで区別する。
- 部分応答は実際に受信したpayload prefixだけ保存する。
- 走行サンプルにも`partial`フラグを保持する。
- Debug Bundleから後日同じ判定を再現できる。

## 4. 初心者UIレビュー

新人の疑問:「Positiveと出ているのに全データが無いのはなぜ？」

回答をUIへ明示:
- `完全`: 応答payload全体を取得できた。
- `部分（末尾欠落）`: ECUはDIDへPositive応答したが、長大応答の末尾をKW905側で取得し切れなかった。
- DIDの存在は確認済みなので探索は次へ進む。

走行CoverageではDIDごとの部分応答数を別列表示する。

## 5. QAレビュー

追加回帰項目:
- Session 15形式の`BUFFER FULL` raw → `positive_partial`
- headerless CAF1 complete/partialの再構成
- partial Positiveがmulti-day resumeで再試行されない
- partial Positiveが5件続いてもinfrastructure error safety stopにならない
- drive sampleのpartial flag DB migration / Debug Bundle export
- Positive inventory詳細で完全/部分statusが保持される
- UIソースに取得状態/部分応答Coverage列が存在する
- Session 15実RAW再解析で17 DID（完全6 + 部分11）を再発見
