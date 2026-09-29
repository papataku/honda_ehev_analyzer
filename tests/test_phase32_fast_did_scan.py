from __future__ import annotations

from honda_analyzer.analysis.did_discovery import estimate_scan_seconds
from honda_analyzer.analysis.did_scan_timing import profile_for_rate, prioritized_scan_ranges


def test_10hz_profile_uses_aggressive_adaptive_timing_and_60ms_cap():
    p=profile_for_rate(10.0)
    assert p.name=='高速'
    assert p.setup_commands==('ATAT2','ATST0F')
    assert p.restore_commands==('ATAT1','ATST32')


def test_5hz_profile_is_less_aggressive():
    p=profile_for_rate(5.0)
    assert p.setup_commands==('ATAT2','ATST19')


def test_full_scan_10hz_is_about_9_1_hours_for_five_ecus():
    sec=estimate_scan_seconds(5,0,0xFFFF,10.0)
    assert 9.0*3600 < sec < 9.2*3600


def test_priority_range_finds_2012_before_0000_but_still_covers_everything():
    rs=prioritized_scan_ranges(0,0xFFFF)
    assert rs[0]==(0x2000,0x20FF)
    assert (0,0x1FFF) in rs and (0x2100,0xFFFF) in rs
    covered=[]
    for a,b in rs:
        covered.extend(range(a,b+1))
    assert len(covered)==0x10000
    assert len(set(covered))==0x10000


def test_small_range_outside_priority_band_keeps_natural_order():
    assert prioritized_scan_ranges(0,0x00FF)==[(0,0x00FF)]


def test_discovery_priority_band_is_actually_probed_first():
    import asyncio
    from honda_analyzer.analysis.did_discovery import AsyncDidDiscovery, DidProbeOutcome
    order=[]
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append((ecu,did))
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id=f'18DAF1{ecu}')
    stop=lambda: len(order)>=3
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,stop_requested=stop,sleep=lambda _:asyncio.sleep(0))
        await eng.run(['01'],0,0xFFFF,rate_hz=1000,speed_check_interval_s=999)
    asyncio.run(run())
    assert [d for _,d in order]==[0x2000,0x2001,0x2002]
