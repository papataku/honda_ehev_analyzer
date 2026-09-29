from __future__ import annotations
from dataclasses import dataclass, asdict
from pathlib import Path
import json

VALID_STATUS={"KNOWN","CANDIDATE","VERIFIED","REJECTED","TODO-VEHICLE-TEST","UNKNOWN"}

@dataclass
class SignalDefinition:
    name: str
    ecu: str|None=None
    header: str|None=None
    service: str|None=None
    did: str|None=None
    pid: str|None=None
    offset: int|None=None
    length: int|None=None
    signed: bool|None=None
    endian: str|None=None
    scale: float|None=None
    bias: float|None=None
    unit: str|None=None
    formula: str|None=None
    status: str="CANDIDATE"
    evidence: list[str]|None=None
    notes: str|None=None

    def validate(self):
        if self.status not in VALID_STATUS: raise ValueError(f"invalid status: {self.status}")
        if self.endian not in (None,"big","little"): raise ValueError("endian must be big/little")
        if self.offset is not None and self.offset < 0: raise ValueError("negative offset")
        if self.length is not None and self.length <= 0: raise ValueError("length must be positive")
        return self


def load_signal_file(path):
    obj=json.loads(Path(path).read_text())
    return obj, [SignalDefinition(**s).validate() for s in obj.get("signals",[])]


def save_signal_file(path, vehicle, definitions, schema_version=1):
    defs=[d.validate() for d in definitions]
    data={"schema_version":schema_version,"vehicle":vehicle,"signals":[asdict(d) for d in defs]}
    Path(path).write_text(json.dumps(data,indent=2,ensure_ascii=False)+"\n")


def smartring_export(definitions):
    out=[]
    for d in definitions:
        d.validate()
        if d.status not in {"KNOWN","VERIFIED"}:
            continue
        out.append({k:v for k,v in asdict(d).items() if k in {
            "name","ecu","header","service","did","pid","offset","length","signed","endian","scale","bias","unit","formula","status"
        } and v is not None})
    return {"schema":"honda-ehev-signal-config","version":1,"signals":out}
