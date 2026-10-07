# Verification record

Date: 2026-10-07. These are local implementation/reviewer results, not independent network admission authority or production deployment receipts.

## Final local checks

| Check | Result |
|---|---|
| `forge build` | Passed with pinned Solidity 0.8.26 |
| `forge test` | 48 reported tests passed, 0 failed; mainnet setup explicitly skipped in the default offline run |
| Fuzzing | 256 cases per fuzz test, including token, both IMD orderings, partial fills, tick crossings and independent differential quote tests |
| Stateful invariants | 2 properties, 64 runs / 2048 handler calls, 0 reverts; reported as one invariant suite by this Foundry version |
| `forge fmt --check` | Passed |
| `python3 tools/check_manifest.py` | Passed |
| `python3 tools/check_bytecode.py` | Passed; runtime sizes: DroneToken 1116 bytes, DroneHook 10650 bytes, DeployDrone 12460 bytes |
| Supplied protected tests | 10 passed, 0 failed, 0 skipped: 7 token and 3 hook checks |
| Explicit mainnet fork suite | 2 passed, 0 failed, 0 skipped |

The protected tests were copied without content changes into temporary `test/scratch/univ4_hook/`, run against built creation code with the required attestation-style constructor inputs and supply/decimals/permission metadata, then removed. Only that supplied floor harness reads environment values. All delivered test sources work without environment variables or filesystem permissions.

Compiler lint emits conservative warnings for timestamp comparisons, signed/narrow casts, and external-call/event ordering. The schedule deliberately uses timestamp, as specified. The cast bounds derive from v4's signed 128-bit pool deltas, capped specified-side quote budget and maximum 4000/10000 fee. Fee mint calls target the immutable canonical manager and do not transfer tokens; sweep sets its guard before unlocking and burns claims before taking IMD. These paths are addressed by arithmetic, conservation and reentrancy tests. This does not represent a Slither/Mythril or formal verification run.

## Mainnet fork and identity evidence

- RPC: `https://ethereum-rpc.publicnode.com`.
- Block: **26140740**, fetched as a decimal block number and independently decoded from the response's hexadecimal `number` to confirm equality.
- Hash: `0xf7b639605d5d3d939a29b7b3bdbf02f606593fa4e202b4503f5803db459766a2`.
- Timestamp: `1791378875`.
- IMD: `0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7`; code present, `symbol()` returned `IMD`, `decimals()` returned `18`.
- Mainnet PoolManager (only a test fixture address; never embedded in deployment source or the manifest): `0x000000000004444c5dc75cB358380D2e3dE08A90`; code present, actual initialization, swaps, settlement, claim redemption and keeper payout succeeded.

The IMD address was sourced from the public [IdentityMD documentation](https://imd.fun/docs), which states: “IMD on Ethereum mainnet: 0xd34a99bc0f67ae1bbd63c660e6d0b0dd03e263b7”. No `network.json` was supplied in the checkout. The manager address was taken from the supplied chain-address reference and verified by code lookup and the functional fork rehearsal, rather than assumed from that table alone.

The successful fork command was:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26140740 -vv
```

Both tests exercise the real external manager and real IMD, with a locally deployed token and mined hook. The wallet is funded with `deal` in fork state. The production chain was not changed. The command was re-run after adding assertions that fully filled exact-input and exact-output swaps honor their requested amounts.

## Manifest check provenance

The previously rejected discriminator is repaired: `kind` is exactly `univ4_hook`. Shape checked against the public `UniV4HookManifest` definition in [Identity-md/worker dist/cli.js](https://github.com/Identity-md/worker/blob/main/dist/cli.js), fetched on the review date. The fetched file's SHA-256 was `7ef8668ecd26821cb6ae161f78601c8c5982441a0dbf43c417356a47c9e9a069`.

Required fields are `kind`, `hook` (`contract`, `constructorArgs`, permission-name array), `token` (contract/name/symbol/decimals), `pool` (pairedCurrency/fee/tickSpacing/initialPrice decimal string), and `notes`. The local checker verifies this project's concrete values. It is not the network's private admission process and cannot attest future factory policy, requester allocation or economic acceptance of the opening price.

## Independent review

The separate reviewer authored the published [security report](SECURITY_REVIEW.md) and independent differential tests now delivered in `test/SpecifiedAmount.t.sol`. Their reproduced low-severity oversized exact-output limitation is retained as a regression and disclosed in the README. Separately attested network contributor review, requester parameters, atomic launch execution and source verification remain release responsibilities. No claim is made that AI peer review replaces a human audit or network attestation.
