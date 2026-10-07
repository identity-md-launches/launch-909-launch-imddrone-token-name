# imdDRONE / DRONE

A fixed-supply ERC-20 and immutable Uniswap v4 IMD fee hook. This repository is a launch deliverable; it has not broadcast a deployment or funded a pool. The separately deployed imdDRONES NFT/reward contract is intentionally absent. A requester funds that contract by an ordinary DRONE transfer from their retained launch allocation.

## Build and verification

All Solidity dependencies are ordinary vendored files; no install, submodule, network, FFI, or filesystem cheatcode permission is needed to build or run the default tests.

```sh
forge build
forge test
forge fmt --check
python3 tools/check_manifest.py
python3 tools/check_bytecode.py
```

Compiler: Solidity **0.8.26**, Cancun EVM, optimizer 200 runs, via IR, `bytecode_hash = "none"`. Dependency commits and licenses are recorded in [DEPENDENCIES.md](docs/DEPENDENCIES.md).

The mainnet suite is explicitly **skipped** in an ordinary offline run. To reproduce the successful fork rehearsal:

```sh
forge test --match-contract MainnetForkTest \
  --fork-url https://ethereum-rpc.publicnode.com \
  --fork-block-number 26140740 -vv
```

No test reads or sets environment variables. The fork uses real deployed IMD and PoolManager code; `deal` funds the test wallet locally, and test liquidity and DRONE are newly deployed in the fork. It does not send transactions to Ethereum.

## Contracts and immutable configuration

- `DroneToken`: name `imdDRONE`, symbol `DRONE`, 18 decimals, no constructor arguments; exactly **1,000,000,000 DRONE** (`10^27` units) minted to the constructor caller. Ordinary transfers and allowances only. No later minting, burning extension, transfer tax, owner, admin, pause, or proxy.
- `DroneHook(IPoolManager manager, address imd, address token)`: fixes all three addresses at construction. The deployment system resolves `$poolManager` and `$token`. IMD is an explicit constructor argument, permitting both currency orderings in tests; the mainnet manifest pins the verified mainnet IMD address.
- `DeployDrone`: optional plain CREATE2 deployment/salt helper, not a wrapper or a required intermediary. No authority over a deployed hook. The launch manifest names **DroneHook itself**.
- `SpecifiedAmount`: internal read-only fill calculation, using canonical v4 swap arithmetic and storage reads. It does not perform swaps, transfer tokens, modify LP fees, or hold assets.

The pool's LP fee is always **12500 pips (1.25%)**, plus the separate IMD hook fee. `beforeSwap` always returns a zero LP-fee override. Nothing calls `updateDynamicLPFee`. The initializer rejects other fees, other currency pairs, and tick spacing other than 60, and records its timestamp exactly once. Every enabled callback and the sweep unlock callback authenticate PoolManager. Initialization and unauthorized callback calls can fail; the legitimate swap path has no address-specific rules or administrative state checks.

Permissions are `beforeInitialize`, `beforeSwap`, `afterSwap`, `beforeSwapReturnDelta`, and `afterSwapReturnDelta`: mask **8396 (`0x20cc`)** out of the low 14 bits. The constructor validates the address. No other permissions are enabled. There is no delegatecall, callcode, selfdestruct, proxy, owner, or upgrade mechanism in the token, hook, or deployment helper.

## Fee definition, rounding, and partial fills

`KEEPER_FEE = 300`, `OPENING_FEE = 4000`, and `OPENING_SECONDS = 3600` are constants. All users and both directions use the same timestamp schedule:

```text
elapsed = timestamp - openedAt
rate = 300 + floor(3700 * (3600 - elapsed) / 3600)  when 0 <= elapsed < 3600
rate = 300                                        thereafter
```

`feeNow()` reports 4000 before initialization. The schedule rounds **down** to whole basis points; at 1800 seconds it is 2150, at 3599 it is 301, and at 3600 it is 300. The token amount also rounds down, so a tiny swap may pay zero hook fee.

The fee base is **gross IMD**: all IMD the trader pays on a buy (including the hook fee), or IMD the pool pays out on a sell (before deducting the hook fee). This gives the same percentage of gross IMD in all four modes:

```text
hook fee = floor(actual gross IMD * rate / 10000)
```

Let `D = 10000`, `r = feeNow()`, and `P` be the pool's IMD amount, including the pool's LP fee when IMD is the input.

| Trade | Return delta | Full-fill calculation |
|---|---|---|
| Buy, exact IMD input budget A | beforeSwap specified delta | fee = floor(A*r/D); pool receives A-fee |
| Buy, exact DRONE output | afterSwap unspecified delta | fee = floor(P*r/(D-r)); trader pays P+fee |
| Sell, exact DRONE input | afterSwap unspecified delta | fee = floor(P*r/D); trader receives P-fee |
| Sell, exact net IMD output A | beforeSwap specified delta | fee = floor(A*r/(D-r)); pool pays A+fee |

Thus a 3% fee on gross IMD is approximately **3.0928% of net IMD**, and the opening 40% is approximately **66.6667% of net IMD**. These are not extra fee tiers: they are the gross/net conversion. Front ends must use this definition when quoting and displaying the fee.

For specified-IMD swaps, `SpecifiedAmount.filled` calculates how much IMD the pool can actually fill, including tick crossings, price limits, liquidity gaps, and PoolManager protocol fees. If input is only partially spent, the fee is recomputed from the fill using `floor(P*r/(D-r))`; if output is partially filled, it is `floor(P*r/D)`. The unused portion incurs no fee. This avoids charging a fee on the entire requested amount when a price limit stops execution. AfterSwap cannot return a specified-currency refund, so this read-only pre-calculation is necessary. It adds gas proportional to the tick traversal already performed by v4; routers should estimate gas normally.

This is a fee-only hook: it does not consume all input to bypass the AMM, initiate nested swaps, inspect the trader or router address, parse hook data, reject wallets, cap balances, or gate trades. The hook returns positive deltas **only in IMD**, balanced by IMD claims minted to itself.

## Fee custody and sweep

Fees accrue as IMD-denominated ERC-6909 claims held by the hook in PoolManager. No IMD transfer or keeper callback occurs during fee collection. This works even when the PoolManager holds zero IMD before the swap's input settlement, including a fresh pool funded only with DRONE.

- `pending()` = redeemable IMD claims plus loose IMD sent directly to the hook.
- `collected()` = cumulative swap fees, never reduced by sweeping; donations are excluded.
- `openedAt()` = pool initialization timestamp, including a valid zero timestamp in tests.
- `sweep()` = anyone may redeem all claims and forward loose IMD to **0x086b47d05aAE785F871191c1198231E9e6033c64**. The keeper is a compile-time constant and cannot be changed. No caller gets a bounty or can choose a recipient.

Sweep unlocks the manager, burns its claims before taking IMD, then forwards any loose balance. A transfer failure rolls the entire sweep back, preserving the claims. Reentrant sweep calls return zero. Calls made while PoolManager is already unlocked also return zero, leaving fees pending; this prevents interference with a router's input settlement. Call again after that transaction. Empty and repeated sweeps are harmless. There are no claim approvals or arbitrary withdrawal methods. Other tokens accidentally sent to the hook cannot be recovered.

## Deployment parameters and responsibilities

[launch.json](launch.json) uses the accepted discriminator **`"kind": "univ4_hook"`** and the public worker's hook manifest shape. It has no hardcoded PoolManager address. The hook constructor arguments are `$poolManager`, the IMD address, and `$token` in that order.

1. Use Ethereum mainnet (chain ID 1). Validate the supplied canonical PoolManager and mainnet IMD code against [the fork record](docs/VERIFICATION.md). Rehearse again at a recent block before release.
2. The economic assumption for this deliverable is **80% pool / 10% contributor network / 10% requester**: 800,000,000 / 100,000,000 / 100,000,000 DRONE. Configure `poolBps = 8000` and `remainderTo = the requester` in the launch request/policy. The requester address is not supplied in this assignment. This allocation is an operational requirement, not a token privilege or an invented field in the hook manifest. **Do not use a default 90% pool / 10% network allocation**, which would leave no DRONE to fund NFT rewards. Confirm the factory's distribution before signing.
3. `initialPrice` is the sqrt-price Q96 value `79228162514264337593543950336`: a documented assumption of **1 IMD per DRONE**, since both have 18 decimals. `tickSpacing = 60`. The price and economic allocation are assumptions to be accepted by the requester/deployer; no market-price oracle is embedded.
4. Deploy the standard token first. Append ABI-encoded manager, IMD, and the actual newly deployed token address to DroneHook creation code. Mine the salt against the **actual CREATE2 deployer's address**, this creation-code hash, and mask `0x20cc`. The helper accepts those inputs explicitly. A salt for the helper is not a salt for a different launch factory.
5. Deploy the hook directly and initialize the matching pool **atomically** through the launch factory. The initialization callback prevents pre-initialization at an address without hook code. Atomicity prevents someone starting the opening clock between deployment and initialization. The helper only demonstrates hook creation; calling it and initializing in separate transactions does not supply this atomic launch guarantee.
6. Add policy-approved liquidity. The factory/LP operator controls positions, ranges, liquidity provisioning and custody; the hook has no LP management powers. Verify total supply, requester receipt, pool ID, actual initial price, LP fee, permission mask, keeper, openedAt, and deployed runtime against compiled artifacts. Verify sources on an explorer.
7. Publish the launch addresses and review. Run a keeper job or call `sweep()` manually when economical; anyone can do it. Monitor pending claims, actual keeper receipts, and LP liquidity. The keeper wallet's custody and the separately deployed NFT contract/reward amount are the requester's responsibilities. The requester transfers only their retained DRONE to that contract; it has no minting or privileged relationship to DRONE or DroneHook.

## Scope of guarantees and review

Successful swaps still require the normal v4 prerequisites: valid price limits, available liquidity, affordable router settlement, and representable signed 128-bit currency deltas **including hook fees**. An exact-output IMD request extremely close to `int256.max` can overflow v4's `amountSpecified + hookFee` even for a tiny price-limited fill. This is an explicitly tested input-domain limitation of positive specified return deltas; quote/UI adapters should restrict amounts to the supported signed 128-bit settlement domain. It is not a wallet cap or mutable trading restriction. Arbitrary failed ERC-20 transfers, out-of-gas, invalid inputs, and the PoolManager itself can still revert a transaction; no hook can promise otherwise.

The mainnet pair must remain an ordinary non-rebasing, non-taxed ERC-20 compatible with v4. IMD and PoolManager are external dependencies whose code/policy are outside this hook's control. The hook's fee recipients, rates and logic cannot be repaired through an admin after deployment.

[SECURITY_REVIEW.md](docs/SECURITY_REVIEW.md) is a published repository report from a separate AI review agent, with differential probes. It is **not** a claim of a human audit or independently attested IdentityMD contributor review. A separately attested network contributor's release review is still required before production funding. Automated tests and the fork rehearsal are evidence, not a substitute for that release approval. No formal verification, Slither, or Mythril run is claimed.

The implementation configuration is general BaseHook-style logic written here without inheriting a privileged base: no shares, no access-control scheme, no custom input parameters; only the five permissions above; safe v4 currency handling; no cross-callback transient storage. The PoolManager itself uses transient storage under Cancun.
