from __future__ import annotations


class OperationGate:
    """Tiny ownership gate for mutually-exclusive asynchronous UI operations.

    Qt signal handlers can schedule multiple coroutines before the next UI refresh.
    This gate rejects overlapping BLE scan/readiness/connect operations and only
    lets the coroutine that acquired the gate release it.
    """

    def __init__(self) -> None:
        self.current: str | None = None

    @property
    def busy(self) -> bool:
        return self.current is not None

    def begin(self, name: str) -> bool:
        name = str(name)
        if self.current is not None:
            return False
        self.current = name
        return True

    def end(self, name: str) -> bool:
        name = str(name)
        if self.current != name:
            return False
        self.current = None
        return True
