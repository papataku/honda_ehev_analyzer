# Session 12 実走行解析メモ

対象: `session-12-20260926-103939` / Analyzer 0.2.8

## 取得品質
- 約20分
- ELM command: 6,579
- RAW BLE notification: 26,997
- command failure: 0
- communication quality: GOOD / score 100
- latency median 約118 ms, p95 約178 ms
- BLE RSSI 約 -67 dBm

## 標準Mode 01
support bitmap walkで46 PIDを検出。走行状態に特に有用だったもの:
- 0C Engine RPM: 1,516 samples
- 0D Vehicle Speed: 1,516 samples
- 49 Accelerator Pedal Position D: 698 samples; RP8では解放時基準が約20%
- 05 Coolant: 173 samples
- 5B Hybrid/EV Battery Pack Remaining Charge: 11 samples; 約40.4–50.6%
- 9A Hybrid/EV Vehicle System Data: 1,059 samples

## PID 9A
RP8 response data bytesは6 byteでsupport maskは0x07。
- HV voltage: 約238.3–264.0 V
- HV current: 約-104.6–+116.4 A
- V×I: 約-27.5–+27.8 kW

Session 12では、正の電力が加速/駆動側、負の電力が減速/充電側と整合した。そのためこの車両についてはUIで `+放電 / -回生・充電` と表示する。

## 5つの010C response ID
`18DAF101 / 18DAF102 / 18DAF106 / 18DAF10E / 18DAF1EF` はほとんど同じEngine RPMを返す。エンジンON/OFF遷移のごく一部で更新タイミング差があるが、EV走行中に車速へ比例して継続回転する別のmotor RPMとは判断できない。

## DID 2012
383 samples、再構成後data長36 byte。
主な変動はbyte 5および24–27付近。ただしEV走行中の車速との単純Pearson相関は、byte/u16 BE/LE候補を総当たりしても最大絶対値がおおむね0.30未満。このcaptureだけではtraction motor RPMとは判定しない。

## 次の解析優先順位
1. PID 5B / 9Aは既知信号として利用し、DID 2012や今後の未知DIDとの相関基準にする。
2. motor/generator RPMは別DID探索対象として維持する。
3. 5 responderのECU役割はresponse IDだけで命名せず、既知DIDへの応答特性を増やして識別する。
