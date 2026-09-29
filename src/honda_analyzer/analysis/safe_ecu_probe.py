from __future__ import annotations

from dataclasses import dataclass
from typing import Callable, Awaitable

from honda_analyzer.analysis.ecu_census import SAFE_CENSUS_REQUESTS, physical_request_id_for_ecu
from honda_analyzer.protocol.can_header import elm327_header_commands, split_29bit_header
from honda_analyzer.protocol.elm_text import find_uds_22_payload


@dataclass
class HeaderState:
    priority: str | None = None
    header: str | None = None


@dataclass(frozen=True)
class ProbeResult:
    ecu: str
    request_id: str
    positive: bool
    response_can_id: str | None
    payload: bytes
    raw_text: str


async def select_header(session, header: str, state: HeaderState, on_result: Callable | None = None) -> HeaderState:
    if state.header == header:
        return state
    priority,_ = split_29bit_header(header)
    for cmd in elm327_header_commands(header, state.priority):
        r = await session.command(cmd, timeout=5.0)
        if on_result:
            on_result(cmd, r)
        if not r.success:
            raise RuntimeError(f'CAN Header {header} selection failed via {cmd}: {r.text.strip()}')
        if cmd.startswith('ATCP'):
            state.priority = priority
    state.header = header
    return state


async def run_safe_census_requests(session, state: HeaderState | None = None, on_result: Callable | None = None):
    """Send only the small, explicit read-only census allow-list once each."""
    state = state or HeaderState()
    results=[]
    for name,cmd,header in SAFE_CENSUS_REQUESTS:
        await select_header(session, header, state, on_result)
        r=await session.command(cmd, timeout=6.0)
        if on_result:
            on_result(cmd, r)
        results.append((name,cmd,header,r))
    return state, results


async def probe_did_2012_once(session, ecu: str, state: HeaderState | None = None, on_result: Callable | None = None):
    """Read DID 2012 exactly once from one observed ECU using physical 29-bit addressing."""
    state = state or HeaderState()
    request_id=physical_request_id_for_ecu(ecu)
    await select_header(session, request_id, state, on_result)
    r=await session.command('222012', timeout=7.0)
    if on_result:
        on_result('222012',r)
    hit=find_uds_22_payload(r.text,0x2012)
    if hit:
        payload,response_id=hit
        return state,ProbeResult(str(ecu).upper(),request_id,True,response_id,payload,r.text)
    return state,ProbeResult(str(ecu).upper(),request_id,False,None,b'',r.text)
