from __future__ import annotations

import re

_HEX8 = re.compile(r'^[0-9A-F]{8}$')


def normalize_29bit_header(header: str) -> str:
    """Return an 8-hex-digit 29-bit CAN identifier.

    ELM327-compatible adapters traditionally split a 29-bit identifier into
    ``ATCP`` (the upper priority byte / five significant bits) and ``ATSH``
    (the lower three bytes).  Many v1.5 clones reject an 8-digit ``ATSH``.
    """
    h = ''.join(str(header).upper().split())
    if not _HEX8.fullmatch(h):
        raise ValueError(f'29-bit CAN header must be exactly 8 hex digits: {header!r}')
    return h


def split_29bit_header(header: str) -> tuple[str, str]:
    h = normalize_29bit_header(header)
    return h[:2], h[2:]


def elm327_header_commands(header: str, current_priority: str | None = None) -> tuple[str, ...]:
    """Commands required to select a 29-bit CAN header on classic ELM327.

    Example: 18DB33F1 -> ATCP18 + ATSHDB33F1.  If priority 18 is already
    active, only the ATSH command is needed when changing the lower 24 bits.
    """
    priority, lower24 = split_29bit_header(header)
    cmds: list[str] = []
    if current_priority is None or current_priority.upper() != priority:
        cmds.append('ATCP' + priority)
    cmds.append('ATSH' + lower24)
    return tuple(cmds)
