import asyncio
from honda_analyzer.storage.db import SessionDB
from honda_analyzer.transport.replay import ReplayTransport
def test_db_raw_immutable_and_recovery(tmp_path):
 db=SessionDB(tmp_path/'x.db');sid=db.create_session('2026-01-01T00:00:00+00:00','abc');db.append_raw(sid,'2026-01-01T00:00:01+00:00','BLE','kw',b'abc');assert db.raw_rows(sid)[0][3]==b'abc';assert db.recover_open_sessions()==[sid];assert db.list_sessions()[0][3]=='RECOVERED'
def test_replay_deterministic():
 rows=[('2026-01-01T00:00:00+00:00','BLE','x',b'a'),('2026-01-01T00:00:01+00:00','BLE','x',b'b')]
 async def run():
  t=ReplayTransport(rows,float('inf'));await t.connect();return (await t.recv()).data,(await t.recv()).data
 assert asyncio.run(run())==(b'a',b'b');assert asyncio.run(run())==(b'a',b'b')
