from __future__ import annotations
from dataclasses import dataclass, field


@dataclass(frozen=True)
class AutoStateResult:
    label: str
    detail: str
    confidence: str


@dataclass
class AutoDriveStateTracker:
    """Conservative state classifier using standard OBD observations.

    When PID 9A HV battery power is fresh, negative HV power during deceleration
    can confirm charging/regeneration on the validated RP8 sign convention.
    Without HV power, deceleration remains a candidate rather than a conclusion.
    """
    values: dict[str, tuple[float, float]] = field(default_factory=dict)
    last_speed: tuple[float, float] | None = None

    def update(self, key: str, value: float, t: float) -> None:
        if key == 'speed':
            old = self.values.get('speed')
            if old is not None:
                self.last_speed = old
        self.values[key] = (float(value), float(t))

    def _fresh(self, key: str, now: float, max_age: float = 2.5):
        hit = self.values.get(key)
        if hit is None or now - hit[1] > max_age:
            return None
        return hit[0]

    def classify(self, now: float) -> AutoStateResult:
        speed = self._fresh('speed', now)
        rpm = self._fresh('rpm', now)
        pedal = self._fresh('pedal', now, 4.0)
        throttle = self._fresh('throttle', now, 4.0)
        load = self._fresh('load', now, 4.0)
        hv_power = self._fresh('hv_power', now, 2.0)
        if speed is None or rpm is None:
            return AutoStateResult('判定待ち', '車速とRPMの取得待ち', '低')

        accel = None
        if self.last_speed is not None:
            ps, pt = self.last_speed
            dt = now - pt
            if 0.15 <= dt <= 3.0:
                accel = (speed - ps) / dt

        engine_on = rpm >= 150.0
        moving = speed >= 1.0
        driver_input = pedal if pedal is not None else throttle

        if not moving:
            base = '停止・エンジンON' if engine_on else '停止'
        else:
            base = 'エンジン走行' if engine_on else 'EV走行候補'

        motion = ''
        if moving and accel is not None:
            if accel >= 0.8:
                motion = '加速'
            elif accel <= -0.8:
                if hv_power is not None and hv_power <= -0.8:
                    motion = '回生'
                elif hv_power is None:
                    motion = '減速／回生候補'
                else:
                    motion = '減速'
            elif abs(accel) <= 0.25:
                motion = '定速'
            else:
                motion = '速度変化中'

        label = base if not motion else f'{base}・{motion}'
        parts = [f'車速 {speed:.0f} km/h', f'RPM {rpm:.0f}']
        if accel is not None: parts.append(f'車速変化 {accel:+.2f} km/h/s')
        if pedal is not None: parts.append(f'アクセル {pedal:.1f}%')
        if throttle is not None: parts.append(f'スロットル {throttle:.1f}%')
        if load is not None: parts.append(f'負荷 {load:.1f}%')
        if hv_power is not None: parts.append(f'HV電力 {hv_power:+.1f} kW')
        confidence = '高' if hv_power is not None else ('高' if pedal is not None else ('中' if throttle is not None else '低'))
        return AutoStateResult(label, ' / '.join(parts), confidence)
