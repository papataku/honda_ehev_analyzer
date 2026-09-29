# 0.2.9 Session 12 — 標準Hybrid/EV信号の確定と走行解析

## 実車Session 12で確認したこと
- 約20分、6579 ELMコマンド、26997 RAW BLE通知、通信エラー0。
- Mode 01 support bitmapから46 PIDを検出し、対応PID巡回が実走行中も成立。
- PID 5Bは `Hybrid/EV Battery Pack Remaining Charge`。100/255 %/bitで、Session 12では約40.4–50.6%。
- PID 9Aは `Hybrid/EV Vehicle System Data`。RP8はsupport mask 0x07で状態・HV電圧・HV電流を提供。
- PID 9A電圧: C,D × 0.015625 V。Session 12では約238.3–264.0 V。
- PID 9A電流: E,F signed int16 × 0.1 A。Session 12では約-104.6–+116.4 A。
- HV電力は voltage × current / 1000。Session 12では約-27.5–+27.8 kW。
- RP8の実走行では正側がバッテリー放電、負側が充電/回生と、加速・減速との整合で確認。
- PID 49のアクセル位置は解放時でも約20%の基準値を持つため、絶対値0–3%を「アクセルOFF」とみなさない。

## 0.2.9での変更
1. ライブダッシュボードにHV SOC、HV電圧、HV電流、HV電力を追加。
2. Offline Replayにも同じ4項目を追加。PID 9Aから電圧/電流/電力を再生成できる。
3. 相関解析の既知信号にHV SOCとHV電力を追加。未知DID fieldをバッテリー挙動と直接比較できる。
4. 自動状態判定は負のHV電力+減速を「回生」と判定。HV電力が無い時だけ「回生候補」とする。
5. AUTO_STATEイベントは1.2秒安定後に記録し、1 km/h量子化などでイベントが大量発生するのを抑える。
6. Macシミュレータも標準PID 5B/9A形式へ更新。

## まだ確定していないもの
- DID 2012の36-byte payloadの意味。
- traction motor / generator RPMやtorque。Session 12の2012主要変動byteは車速との単純相関が弱く、モーターRPMと断定できない。
- 5つのresponse CAN IDのECU役割名。

これらはUNKNOWN/CANDIDATEのまま維持する。
