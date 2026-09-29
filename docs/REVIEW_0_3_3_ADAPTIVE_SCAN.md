# 0.3.3 適応DID探索レビュー

## 探索アルゴリズム担当
- 16領域の粗探索で早期にhot sectorを見つける。
- sectorをさらに0x100 pageへ分け、先頭/中央の2代表点でhot pageを推定する。
- hot pageは次のsectorへ進む前に即時深掘りする。
- 最後のexhaustive fillにより、sentinelが外れてもDIDを見落とさない。

## 車載通信担当
- 10 req/sは送信目標。直列ELM promptモデルを維持し、パイプライン送信しない。
- 高速時のみATAT2/ATST0F。NO DATA/timeoutはterminal扱いしない。
- ヘッダ切替はpage単位を基本とし、1 DIDごとの不要な切替を避ける。

## 安全担当
- UDS 0x22 read-onlyのみ。
- 2秒周期の実車速確認を維持。
- 車速>0または車速取得不能で停止。
- 通信/ヘッダエラー5連続で停止。

## 再現性担当
- Positive/NRC31のresume semanticsを維持。
- 過去Positiveをpriority hintとして再開時に復元。
- 全Coverageテストで重複/欠落がないことを確認。

## 初心者UI担当
- 画面に5段階の探索順を日本語で説明。
- 現在フェーズを進捗表示へ追加。
- 「代表点で無反応=領域を省略」ではないことを明記。
