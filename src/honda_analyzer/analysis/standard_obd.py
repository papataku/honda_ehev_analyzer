from __future__ import annotations
from dataclasses import dataclass
from typing import Callable
from honda_analyzer.protocol.elm_text import isotp_messages


@dataclass(frozen=True)
class StandardPid:
    pid: int
    name_ja: str
    unit: str
    decoder: Callable[[bytes], float | int | str | None] | None = None
    state_priority: int = 0
    note_ja: str = ''


def _pct1(p: bytes): return None if len(p) < 1 else p[0] * 100.0 / 255.0
def _temp1(p: bytes): return None if len(p) < 1 else p[0] - 40
def _u8(p: bytes): return None if len(p) < 1 else p[0]
def _u16(p: bytes): return None if len(p) < 2 else (p[0] << 8) | p[1]
def _rpm(p: bytes): return None if len(p) < 2 else ((p[0] << 8) | p[1]) / 4.0
def _maf(p: bytes): return None if len(p) < 2 else ((p[0] << 8) | p[1]) / 100.0
def _voltage(p: bytes): return None if len(p) < 2 else ((p[0] << 8) | p[1]) / 1000.0
def _abs_load(p: bytes): return None if len(p) < 2 else ((p[0] << 8) | p[1]) * 100.0 / 255.0
def _torque_pct(p: bytes): return None if len(p) < 1 else p[0] - 125
def _fuel_rate(p: bytes): return None if len(p) < 2 else ((p[0] << 8) | p[1]) / 20.0


# A deliberately focused human-readable subset. The sweep still preserves RAW for
# every PID that the vehicle reports as supported, even if it is not decoded here.
STANDARD_PIDS: dict[int, StandardPid] = {
    0x04: StandardPid(0x04, '計算エンジン負荷', '%', _pct1, 2),
    0x05: StandardPid(0x05, '冷却水温', '°C', _temp1, 1),
    0x0B: StandardPid(0x0B, '吸気マニホールド圧', 'kPa', _u8, 1),
    0x0C: StandardPid(0x0C, 'エンジン回転数', 'rpm', _rpm, 5),
    0x0D: StandardPid(0x0D, '車速', 'km/h', _u8, 5),
    0x0F: StandardPid(0x0F, '吸気温', '°C', _temp1, 1),
    0x10: StandardPid(0x10, 'MAF空気流量', 'g/s', _maf, 2),
    0x11: StandardPid(0x11, 'スロットル開度', '%', _pct1, 4),
    0x1F: StandardPid(0x1F, 'エンジン始動後時間', 's', _u16, 1),
    0x33: StandardPid(0x33, '大気圧', 'kPa', _u8, 1),
    0x42: StandardPid(0x42, '制御モジュール電圧', 'V', _voltage, 1),
    0x43: StandardPid(0x43, '絶対負荷', '%', _abs_load, 2),
    0x45: StandardPid(0x45, '相対スロットル開度', '%', _pct1, 3),
    0x47: StandardPid(0x47, 'スロットル位置B', '%', _pct1, 2),
    0x48: StandardPid(0x48, 'スロットル位置C', '%', _pct1, 2),
    0x49: StandardPid(0x49, 'アクセルペダル位置D', '%', _pct1, 5),
    0x4A: StandardPid(0x4A, 'アクセルペダル位置E', '%', _pct1, 4),
    0x4B: StandardPid(0x4B, 'アクセルペダル位置F', '%', _pct1, 4),
    0x4C: StandardPid(0x4C, '指令スロットルアクチュエータ', '%', _pct1, 2),
    0x5A: StandardPid(0x5A, '相対アクセルペダル位置', '%', _pct1, 5),
    0x5B: StandardPid(0x5B, 'HVバッテリーSOC（残量）', '%', _pct1, 4,
                      'SAE J1979: Hybrid/EV Battery Pack Remaining Charge。100/255 %。'),
    0x5C: StandardPid(0x5C, 'エンジンオイル温度', '°C', _temp1, 1),
    0x5E: StandardPid(0x5E, 'エンジン燃料流量', 'L/h', _fuel_rate, 2),
    0x61: StandardPid(0x61, 'ドライバー要求エンジントルク', '%', _torque_pct, 3),
    0x62: StandardPid(0x62, '実エンジントルク', '%', _torque_pct, 3),
    0x63: StandardPid(0x63, 'エンジン基準トルク', 'N·m', _u16, 2),
}

SUPPORT_BITMAP_PIDS = (0x00, 0x20, 0x40, 0x60, 0x80, 0xA0, 0xC0, 0xE0)


@dataclass(frozen=True)
class HybridEvData:
    support_mask: int
    mode: int
    voltage_v: float | None
    current_a: float | None

    @property
    def power_kw(self) -> float | None:
        if self.voltage_v is None or self.current_a is None:
            return None
        return self.voltage_v * self.current_a / 1000.0


def decode_hybrid_ev_9a(text: str) -> HybridEvData | None:
    """Decode SAE J1979 Mode 01 PID 9A from the first responder.

    Data bytes after 41 9A:
      A support bitmap (bit1 voltage, bit2 current; bit0 vehicle/charging state)
      B vehicle/charging state
      C,D battery-system voltage, 0.015625 V/bit
      E,F battery-system current, signed int16, 0.1 A/bit

    RP8 session-12 evidence matches positive=current discharge and
    negative=current charge/regeneration.  The numeric decode itself follows
    J1979 scaling; callers may label direction conservatively if desired.
    """
    payloads = all_mode01_payloads(text, 0x9A)
    if not payloads:
        return None
    p = payloads[0][1]
    if len(p) < 6:
        return None
    support = p[0]
    mode = p[1]
    voltage = (((p[2] << 8) | p[3]) * 0.015625) if (support & 0x02) else None
    raw_current = (p[4] << 8) | p[5]
    if raw_current >= 0x8000:
        raw_current -= 0x10000
    current = (raw_current * 0.1) if (support & 0x04) else None
    return HybridEvData(support, mode, voltage, current)


def mode01_command(pid: int) -> str:
    return f'01{pid:02X}'


def all_mode01_payloads(text: str, pid: int) -> list[tuple[str | None, bytes]]:
    prefix = bytes((0x41, pid & 0xFF))
    out: list[tuple[str | None, bytes]] = []
    for msg in isotp_messages(text):
        i = msg.payload.find(prefix)
        if i >= 0:
            out.append((msg.can_id, bytes(msg.payload[i + 2:])))
    return out


def supported_pids_from_bitmap_response(text: str, base_pid: int) -> set[int]:
    """Union supported Mode 01 PIDs across every responder to a bitmap query."""
    supported: set[int] = set()
    for _can_id, payload in all_mode01_payloads(text, base_pid):
        if len(payload) < 4:
            continue
        mask = int.from_bytes(payload[:4], 'big')
        for bit in range(32):
            if mask & (1 << (31 - bit)):
                supported.add(base_pid + bit + 1)
    return supported


def should_continue_bitmap(text: str, base_pid: int) -> bool:
    return (base_pid + 0x20) in supported_pids_from_bitmap_response(text, base_pid)


def decode_standard_pid(pid: int, text: str):
    spec = STANDARD_PIDS.get(pid)
    if not spec or not spec.decoder:
        return None
    payloads = all_mode01_payloads(text, pid)
    if not payloads:
        return None
    # Dashboard/state label uses the first responder. Every responder remains in
    # the command RAW and response inventory for offline analysis.
    return spec.decoder(payloads[0][1])


def pick_state_pid(supported: set[int], candidates: tuple[int, ...]) -> int | None:
    for pid in candidates:
        if pid in supported:
            return pid
    return None


def state_pid_choices(supported: set[int]) -> dict[str, int | None]:
    return {
        'rpm': pick_state_pid(supported, (0x0C,)),
        'speed': pick_state_pid(supported, (0x0D,)),
        'pedal': pick_state_pid(supported, (0x49, 0x5A, 0x4A, 0x4B)),
        'throttle': pick_state_pid(supported, (0x11, 0x45, 0x47, 0x48)),
        'load': pick_state_pid(supported, (0x04, 0x43)),
        'driver_torque': pick_state_pid(supported, (0x61,)),
        'engine_torque': pick_state_pid(supported, (0x62,)),
    }


@dataclass(frozen=True)
class Did2012CandidateData:
    soc_percent_candidate: float | None


def decode_did2012_candidates(text: str) -> Did2012CandidateData | None:
    """Extract evidence-backed candidates from Honda DID 0x2012.

    RP8 session-13 evidence: data byte index 5 closely tracks standard PID 5B
    SOC (734 aligned samples, MAE about 0.43 percentage points, 93.7% within
    +/-1 point).  This is intentionally labelled a candidate because no Honda
    public DID definition has been used to confirm the semantic meaning.
    """
    from honda_analyzer.protocol.elm_text import find_uds_22_payload
    hit = find_uds_22_payload(text, 0x2012)
    if hit is None:
        return None
    payload, _can_id = hit
    if len(payload) <= 5:
        return None
    return Did2012CandidateData(float(payload[5]))
