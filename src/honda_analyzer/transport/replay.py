import asyncio
from datetime import datetime
from .base import Transport,RawChunk
class ReplayTransport(Transport):
 def __init__(self,rows,speed=1.0): self.rows=list(rows);self.speed=speed;self.i=0;self.connected=False;self.tx=[]
 async def connect(self):self.connected=True;self.i=0
 async def disconnect(self):self.connected=False
 async def write(self,data):self.tx.append(bytes(data))
 async def recv(self):
  if self.i>=len(self.rows):raise EOFError('replay complete')
  ts,layer,source,payload=self.rows[self.i];self.i+=1
  if self.speed!=float('inf') and self.i>1:
   prev=datetime.fromisoformat(self.rows[self.i-2][0]);cur=datetime.fromisoformat(ts);await asyncio.sleep(max(0,(cur-prev).total_seconds()/self.speed))
  return RawChunk(payload,f'replay:{source}',datetime.fromisoformat(ts))
 def step(self):
  if self.i>=len(self.rows):return None
  ts,layer,source,payload=self.rows[self.i];self.i+=1;return RawChunk(payload,f'replay:{source}',datetime.fromisoformat(ts))
