"""Bleak transport for ELM327-compatible BLE adapters such as KW905.
GATT characteristics are discovered at runtime; no vendor UUID is assumed.
"""
from __future__ import annotations
import asyncio
from dataclasses import dataclass, asdict
from .base import Transport, RawChunk

@dataclass(frozen=True)
class GattCharacteristic:
    service_uuid: str
    uuid: str
    properties: tuple[str, ...]

@dataclass(frozen=True)
class BleDeviceInfo:
    identifier: str
    name: str | None
    rssi: int | None = None

async def scan_devices(timeout: float=5.0) -> list[BleDeviceInfo]:
    from bleak import BleakScanner
    found = await BleakScanner.discover(timeout=timeout, return_adv=True)
    out=[]
    for _key,(dev,adv) in found.items():
        out.append(BleDeviceInfo(str(dev.address), dev.name or adv.local_name, getattr(adv,'rssi',None)))
    return sorted(out, key=lambda x: (x.name or '', x.identifier))

def choose_gatt_pair(gatt: list[GattCharacteristic]) -> tuple[str|None,str|None]:
    """Choose a UART-like write/notify pair without assuming vendor UUIDs.

    Prefer one characteristic that supports both directions, then a pair from
    the same service. Falling back to unrelated services is deliberately last.
    """
    def can_write(c): return 'write-without-response' in c.properties or 'write' in c.properties
    def can_notify(c): return 'notify' in c.properties or 'indicate' in c.properties
    both=sorted((c for c in gatt if can_write(c) and can_notify(c)),key=lambda c: 'write-without-response' not in c.properties)
    if both:return both[0].uuid,both[0].uuid
    writes=sorted((c for c in gatt if can_write(c)),key=lambda c: 'write-without-response' not in c.properties); notifies=[c for c in gatt if can_notify(c)]
    for w in writes:
        n=next((x for x in notifies if x.service_uuid==w.service_uuid),None)
        if n:return w.uuid,n.uuid
    return (writes[0].uuid if writes else None,notifies[0].uuid if notifies else None)

class KW905BleTransport(Transport):
    def __init__(self, device_id: str, write_char: str|None=None, notify_char: str|None=None, raw_hook=None):
        self.device_id=device_id; self.write_char=write_char; self.notify_char=notify_char
        self.raw_hook=raw_hook; self.client=None; self.rx=asyncio.Queue(); self.gatt=[]; self.mtu_size=None
    async def connect(self):
        from bleak import BleakClient
        # Never carry stale notifications across a disconnect/reconnect gate.
        while not self.rx.empty():
            try:self.rx.get_nowait()
            except asyncio.QueueEmpty:break
        self.client=BleakClient(self.device_id)
        await self.client.connect()
        self.mtu_size=getattr(self.client,'mtu_size',None)
        self.gatt=[]
        for svc in self.client.services:
            for ch in svc.characteristics:
                self.gatt.append(GattCharacteristic(str(svc.uuid),str(ch.uuid),tuple(ch.properties)))
        auto_w,auto_n=choose_gatt_pair(self.gatt)
        if not self.write_char:self.write_char=auto_w
        if not self.notify_char:self.notify_char=auto_n
        if not self.write_char or not self.notify_char:
            raise RuntimeError('No suitable BLE write/notify characteristics found; inspect the GATT inventory')
        def cb(sender,data):
            chunk=RawChunk.now(bytes(data), f'ble:{sender}')
            if self.raw_hook:self.raw_hook(chunk)
            self.rx.put_nowait(chunk)
        await self.client.start_notify(self.notify_char, cb)
    async def disconnect(self):
        if self.client:
            if self.notify_char and self.client.is_connected:
                try: await self.client.stop_notify(self.notify_char)
                except Exception: pass
            await self.client.disconnect()
    async def write(self,data:bytes):
        if not self.client or not self.client.is_connected: raise RuntimeError('BLE not connected')
        ch=next((c for c in self.gatt if c.uuid==self.write_char),None)
        response=not (ch and 'write-without-response' in ch.properties)
        await self.client.write_gatt_char(self.write_char,data,response=response)
    async def recv(self): return await self.rx.get()
    def inspector_snapshot(self): return [asdict(x) for x in self.gatt]
