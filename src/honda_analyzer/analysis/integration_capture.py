from __future__ import annotations
from dataclasses import dataclass, asdict
from datetime import datetime, timezone
import asyncio, json, hashlib
from pathlib import Path
from honda_analyzer.protocol.elm_session import ElmSession

@dataclass
class CaptureStep:
    command: str
    success: bool
    text: str
    raw_hex: str
    latency_ms: float
    error: str|None = None

async def run_capture_sequence(transport, commands, timeout=0.25, reconnect=True):
    """Exercise the real ElmSession path and preserve every command outcome."""
    await transport.connect(); session=ElmSession(transport); out=[]
    for cmd in commands:
        try:
            r=await session.command(cmd,timeout=timeout)
            out.append(CaptureStep(cmd,r.success,r.text,r.raw.hex(),r.latency_ms,None))
        except (asyncio.TimeoutError, TimeoutError) as e:
            out.append(CaptureStep(cmd,False,'','',0.0,'TIMEOUT'))
        except ConnectionError as e:
            out.append(CaptureStep(cmd,False,'','',0.0,f'DISCONNECT: {e}'))
            if reconnect:
                await transport.connect(); session=ElmSession(transport)
        except Exception as e:
            out.append(CaptureStep(cmd,False,'','',0.0,f'{type(e).__name__}: {e}'))
    try: await transport.disconnect()
    except Exception: pass
    return out

def write_golden_capture(path, steps):
    path=Path(path); payload={'format':'honda-analyzer-integration-capture-v1','synthetic':True,'steps':[asdict(x) for x in steps]}
    blob=json.dumps(payload,sort_keys=True,indent=2).encode(); path.write_bytes(blob)
    return hashlib.sha256(blob).hexdigest()
