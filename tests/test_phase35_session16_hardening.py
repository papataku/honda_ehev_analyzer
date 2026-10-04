from honda_analyzer.gui.operation_gate import OperationGate


def test_operation_gate_rejects_overlap_and_requires_owner_to_release():
    gate = OperationGate()

    assert gate.begin("scan")
    assert gate.busy
    assert gate.current == "scan"

    assert not gate.begin("readiness")
    assert gate.current == "scan"

    assert not gate.end("readiness")
    assert gate.current == "scan"

    assert gate.end("scan")
    assert not gate.busy
    assert gate.current is None

    assert gate.begin("connect")
    assert gate.end("connect")
