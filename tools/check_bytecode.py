#!/usr/bin/env python3
"""Scan executable opcode positions in built production runtime templates, skipping PUSH data.
Foundry also checks actual deployed runtimes (including their immutable values) in unit tests.
"""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
for contract in ("DroneToken", "DroneHook", "DeployDrone"):
    artifact = json.loads((root / "out" / (contract + ".sol") / (contract + ".json")).read_text())
    code = bytes.fromhex(artifact["deployedBytecode"]["object"].removeprefix("0x"))
    assert 0 < len(code) <= 24576, (contract, "EIP-170 size")
    pc = 0
    while pc < len(code):
        op = code[pc]
        assert op not in (0xf2, 0xf4, 0xff), (contract, hex(pc), hex(op))
        pc += 1 + (op - 0x5f if 0x60 <= op <= 0x7f else 0)
    print(f"{contract}: {len(code)} runtime bytes; no CALLCODE, DELEGATECALL or SELFDESTRUCT")
