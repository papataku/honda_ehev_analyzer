# 0.3.0 — Session 13 regression and DID 2012 evidence

## Session 13
- 47分46秒、20,405 command rows、26,997 BLE RAW notifications。
- 見かけ上のerror rate 14%はKW905/CAN通信エラーではなく、PID 9Aの正常受信後に発生したアプリ内表示例外。
- `019A`は2,735件の実受信成功。正常行の直後に `KeyError: HV Battery Voltage` が失敗行として二重記録されていた。

## 0.3.0 fix
通信/プロトコル成功と、デコード/UI処理成功を分離する。RAW受信済みなら、後段UI例外をvehicle command failureとして保存しない。`live_decode_error`として別記録する。

## DID 0x2012
Session 13では1,002件のpositive responseを取得。data byte index 5と標準PID 5B SOCを734点で時間同期比較した。
- Pearson: 約0.99895
- 平均絶対誤差: 約0.43 percentage points
- 93.7%が±1 point以内

したがってByte 5を `SOCミラー候補` として表示する。ただしHonda公式DID定義は確認できていないため、確定信号へは昇格しない。Bytes 24-27もSOCと非常に強く連動するが、物理意味はUNKNOWNのままとする。
