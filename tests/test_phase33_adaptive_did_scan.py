from __future__ import annotations

import asyncio

from honda_analyzer.analysis.did_discovery import AsyncDidDiscovery, DidProbeOutcome
from honda_analyzer.analysis.did_scan_strategy import (
    outcome_interest_score,
    page_sentinel_dids,
    sector_head_dids,
)


def test_sector_head_sampling_covers_all_16_major_regions():
    xs=list(sector_head_dids(0,0xFFFF,width=1))
    assert xs == [i << 12 for i in range(16)]


def test_page_sentinels_use_head_and_midpoint():
    xs=list(page_sentinel_dids(3,0x3000,0x31FF))
    assert xs[:4] == [0x3000,0x3080,0x3100,0x3180]


def test_interest_scoring_prioritizes_positive_and_condition_nrc_not_nrc31():
    assert outcome_interest_score('positive') > outcome_interest_score('nrc',0x22) > 0
    assert outcome_interest_score('nrc',0x31) == 0
    assert outcome_interest_score('timeout') == 0


def test_positive_sector_head_promotes_that_sector_for_page_survey():
    order=[]
    completed={'01': set(range(0x2000,0x2100))}
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append(did)
        if did == 0x3000:
            return DidProbeOutcome(ecu,did,'positive',1.0,payload=b'X',response_can_id='18DAF101')
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id='18DAF101')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        # Stop after coarse survey plus the first sparse-page probe.
        stop=lambda: len(order)>=62
        eng.stop_requested=stop
        await eng.run(['01'],0,0xFFFF,rate_hz=10000,completed_by_ecu=completed)
    asyncio.run(run())
    # 16 sectors * 4 head probes minus four already-completed 0x2000..0x2003 = 60.
    # Sector 3 had the positive, so phase 3 starts there. 0x3000 is already
    # attempted, making 0x3080 the first new page representative.
    assert len(order) >= 61
    assert order[60] == 0x3080


def test_hot_page_is_fully_scanned_before_exhaustive_fill():
    order=[]
    # Keep the requested interval modest but large enough to include two sectors.
    # Mark 0x2000-20ff complete so the known-page phase is skipped.
    completed={'01': set(range(0x2000,0x2100))}
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append(did)
        if did == 0x1180:
            return DidProbeOutcome(ecu,did,'positive',1.0,payload=b'Y',response_can_id='18DAF101')
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id='18DAF101')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        await eng.run(['01'],0x0000,0x2FFF,rate_hz=100000,completed_by_ecu=completed)
    asyncio.run(run())
    # 0x1180 is a sparse representative. Once all representatives are sampled,
    # page 0x11 must be deep-scanned before ordinary exhaustive fill. Verify a
    # nearby unsampled DID occurs before an unrelated exhaustive DID such as 0x0101.
    assert 0x1101 in order and 0x0101 in order
    assert order.index(0x1101) < order.index(0x0101)


def test_historical_positive_hint_restores_priority_after_restart():
    order=[]
    completed={'01': {0x3488}}
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append(did)
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id='18DAF101')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        # Skip known 0x2000 page via requested range and stop just into page survey.
        eng.stop_requested=lambda: len(order)>=65
        await eng.run(
            ['01'],0x0000,0x4FFF,rate_hz=100000,
            completed_by_ecu=completed,
            positive_hints_by_ecu={'01': {0x3488}},
            prioritize_2000=False,
        )
    asyncio.run(run())
    # 5 sectors * 4 head probes = 20. Historical sector 3 should be first in
    # sparse page survey. 0x3000 was already a sector-head probe, so the next
    # representative in the promoted sector is 0x3080.
    assert order[20] == 0x3080


def test_hot_sector_deep_scan_happens_before_next_cold_sector_page_survey():
    order=[]
    completed={'01': set(range(0x2000,0x2100))}
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append(did)
        if did == 0x3000:
            return DidProbeOutcome(ecu,did,'positive',1.0,payload=b'Z',response_can_id='18DAF101')
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id='18DAF101')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        await eng.run(['01'],0,0x4FFF,rate_hz=100000,completed_by_ecu=completed)
    asyncio.run(run())
    # Sector 3 is promoted by the coarse 0x3000 positive. Its page 0x30 is then
    # deep-scanned before the sparse survey moves on to cold sector 0.
    assert 0x3001 in order and 0x0080 in order
    assert order.index(0x3001) < order.index(0x0080)


def test_adaptive_order_preserves_complete_coverage_without_duplicates():
    order=[]
    async def speed(): return 0.0
    async def probe(ecu,did):
        order.append((ecu,did))
        return DidProbeOutcome(ecu,did,'nrc',1.0,nrc=0x31,response_can_id=f'18DAF1{ecu}')
    async def run():
        eng=AsyncDidDiscovery(probe,speed,lambda _x:None,sleep=lambda _:asyncio.sleep(0))
        await eng.run(['01','02'],0x0000,0x02FF,rate_hz=100000,prioritize_2000=False)
    asyncio.run(run())
    expected={(ecu,did) for ecu in ('01','02') for did in range(0x0000,0x0300)}
    assert set(order)==expected
    assert len(order)==len(expected)
