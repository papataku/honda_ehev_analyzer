import asyncio
from honda_analyzer.transport.mock import MockTransport
from honda_analyzer.protocol.elm_session import ElmSession
from honda_analyzer.protocol.elm_text import find_obd_payload
from honda_analyzer.analysis.known_signals import decode

def test_elm_session_fragmentation():
 async def go():
  t=MockTransport();s=ElmSession(t); task=asyncio.create_task(s.command('ATI'))
  await asyncio.sleep(0);assert t.tx==[b'ATI\r'];t.feed(b'ELM');t.feed(b'327 v1.5>');r=await task;assert r.success and 'ELM327' in r.text
 asyncio.run(go())
def test_obd_text_header_tolerant():
 p=find_obd_payload('18DAF110 04 41 0C 1A F8\r> ',1,0x0c);assert p[:2]==bytes.fromhex('1AF8');assert decode('Engine RPM',p)==1726
