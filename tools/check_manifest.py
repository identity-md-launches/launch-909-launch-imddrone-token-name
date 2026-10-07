#!/usr/bin/env python3
"""Offline structural/semantic checks for this launch's public UniV4HookManifest shape."""
import json
from pathlib import Path

root = Path(__file__).resolve().parents[1]
m = json.loads((root / "launch.json").read_text())
assert set(m) == {"kind", "hook", "token", "pool", "notes"}
assert m["kind"] == "univ4_hook"
assert m["hook"]["contract"] == "DroneHook"
assert m["hook"]["constructorArgs"] == ["$poolManager", m["pool"]["pairedCurrency"], "$token"]
assert m["hook"]["permissions"] == ["beforeInitialize", "beforeSwap", "afterSwap", "beforeSwapReturnDelta", "afterSwapReturnDelta"]
assert m["token"] == {"contract": "DroneToken", "name": "imdDRONE", "symbol": "DRONE", "decimals": 18}
assert m["pool"] == {"pairedCurrency": "0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7", "fee": 12500,
                     "tickSpacing": 60, "initialPrice": "79228162514264337593543950336"}
assert isinstance(m["notes"], str) and len(m["notes"]) <= 4000
print("launch.json: expected univ4_hook schema and deployment parameters verified")
