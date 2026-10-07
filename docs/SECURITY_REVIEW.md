# Independent implementation review

Review date: 2026-10-07. Reviewer: a separate AI security-review agent, distinct from the implementation agent. This is an independent adversarial implementation review within this assignment, **not a third-party human audit, formal verification, or a warranty**. No transactions were broadcast and no funded wallet was used.

## Scope and method

Reviewed `src/DroneHook.sol`, `src/SpecifiedAmount.sol`, `src/DroneToken.sol`, `src/HookFlags.sol`, `script/DeployDrone.sol`, `launch.json`, and the associated Foundry fixtures. Compared the specified-side quote against the vendored Uniswap v4 `Pool.swap`, `SwapMath`, `TickBitmap`, `Hooks`, `BalanceDelta`, and protocol-fee code. Read the supplied Ethereum and v4 security references as review checklists; their suggested administrative powers and router allowlists are inappropriate for this immutable, address-neutral brief and were not added.

Threats considered included forged callbacks, wrong currency orientation, exact-output gross-up, partial fills, zero-liquidity gaps, tick crossing, integer extremes, mutable fees, fee-claim diversion, token transfer reentrancy, failed sweeps, initialization front-running, mismatched permission bits, and delegated execution. The review did not audit all upstream dependencies or the separately deployed NFT contract.

## Result and findings

No critical, high, or medium-severity exploit was identified in the reviewed implementation. One low-severity input limitation remains; deployment and gas assumptions follow below. Absence of a finding does not establish absence of vulnerabilities.

| ID | Severity | Status | Finding |
| --- | --- | --- | --- |
| R-01 | Low | Documented limitation | Exact-output requests extremely close to `int256.max` can overflow the manager's addition of the specified-side hook fee, even where an unhooked price-limited request would partially fill. |
| R-02 | Informational | Operational requirement | Hook deployment and initialization must be atomic for the intended launch price and opening time. The optional CREATE2 helper deploys only the hook. |
| R-03 | Informational | Design tradeoff | Specified-side fee accuracy requires a read-only tick walk before the actual pool walk; gas increases with ticks traversed. |

### R-01: oversized exact-output sentinel

For a sell specifying IMD output, `beforeSwap` correctly returns a positive specified-currency fee. Canonical v4 then performs the checked addition `amountToSwap += hookDeltaSpecified`. A request of `type(int256).max` plus any nonzero fee overflows before the price-limited swap executes. An independent regression reproduced a successful partial fill on an unhooked pool and a revert for the same extreme request on the hooked pool.

This is a caller-input limitation, not theft, corruption, a persistent denial of service, or a per-address rule. Normal economic amounts are many orders of magnitude smaller. It is nevertheless stricter than the unhooked pool and must not be described as an unconditional promise that every arbitrary 256-bit request succeeds. Routers should specify the desired output, keep grossed-up requests representable as `int256`, and keep settled currency deltas representable as `int128`; they should not use `int256.max` as an unlimited-output sentinel. Charging a specified-side return fee without this addition would require different core semantics. Regression coverage also exercises enormous requests with sufficient addition headroom.

### R-02: initialization is permissionless after deployment

The hook accepts exactly one pair, static fee 12500 and tick spacing 60, but does not authorize a particular initializer or enforce an initial price. This preserves the requested absence of an owner or per-address logic. The launch factory must deploy the token and mined hook and initialize the intended pool in the same transaction. Required initialization callback permission prevents initialization while the predicted hook has no code. The optional `DeployDrone` helper is a salt/deployment utility, not a complete launch orchestrator: a separate public initialization transaction would expose the opening price and time to front-running. Do not use that two-transaction sequence for production.

### R-03: quote gas

`SpecifiedAmount` follows the pool's tick bitmap and initialized liquidity transitions. It does not iterate over attacker-provided arrays, but a path through many initialized ticks still costs gas in both quote and execution. A universal no-revert promise cannot include out-of-gas execution, invalid native pool parameters, insufficient settlement, external token failures, or unrepresentable deltas. Assess gas for the actual liquidity distribution and transaction gas limit before release; no gas cap or transaction-size restriction is introduced by this hook.

## Fee accounting

The fee rate is `300 + floor(3700 * (3600 - elapsed) / 3600)` bps during the opening hour and exactly 300 bps thereafter. It rounds the linear rate down. Initialization cannot reset the schedule. The 12500-pip LP fee is static; the hook returns zero for LP override and never updates the LP fee.

Let `r` be that rate, `B = 10000`, `P` the pool's IMD input on a buy, `G` its gross IMD output on a sell, and `F` the hook fee. Buys charge against total IMD paid, including the hook fee: `F = floor((P + F) * r / B)`. Sells charge `F = floor(G * r / B)`. This gross convention must also be used by the front end.

| Mode | Callback | Accounting |
| --- | --- | --- |
| Buy, exact input | `beforeSwap` | Reserve `floor(requested * r / B)`; quote the remaining pool input. For a partial fill charge `floor(actualPoolInput * r / (B-r))`. |
| Sell, exact output | `beforeSwap` | Gross up the desired net IMD output, quote actual fill, charge `floor(actualGrossOutput * r / B)`. |
| Buy, exact output | `afterSwap` | Charge `floor(actualPoolInput * r / (B-r))` on the unspecified IMD input. |
| Sell, exact input | `afterSwap` | Charge `floor(actualGrossOutput * r / B)` on the unspecified IMD output. |

The gross-up identity is exact with integer arithmetic: if `F = floor(P*r/(B-r))`, then `floor((P+F)*r/B) = F`. For a full specified-input fill the direct reserve preserves the user's input budget. For a limited fill, the quoted fee is reduced to the amount actually filled. Reducing the reserve increases the remaining input budget, or reduces an output target that still exceeds the limit's attainable net output, so execution reaches the same limit. The quote uses live canonical manager storage and the same `SwapMath` rounding, tick compression, word masks, directional protocol fee, and initialized liquidity updates as v4. No external token callback or state mutation occurs between that quote and the swap; fee claim minting does not modify pool state.

The hook changes only the IMD component regardless of address ordering. Every positive fee return is paired with `poolManager.mint` of the same IMD claim, canceling the hook's transient debit when the manager accounts its return delta. Input settlement then backs the claim. This avoids transferring IMD before the router has paid it, including a new manager with DRONE-only liquidity. A failed overall unlock rolls back fee claims and `collected` together.

## Access, reentrancy, deployment, and token review

All enabled callbacks and the unlock callback require the immutable manager. Swap logic ignores sender and hook data. Only the configured pair can initialize, and canonical manager initialization prevents other pools from reaching trading with this hook. No owner, administrative fee setter, pause, wallet limit, router allowlist, rescue destination, proxy, or upgrade path was found.

`sweep` has a storage guard, defers when the manager is already unlocked, burns existing claims before taking IMD, and always pays the constant keeper. Reentrant sweeps are harmless no-ops. A failed transfer reverts the entire redemption and restores claims. Direct IMD donations are also swept; they increase `pending`, not `collected`. No token transfer occurs in the fee callbacks, so keeper/token transfer failure cannot itself poison swap callback state. The canonical IMD token and manager remain external trust assumptions.

The no-argument token mints exactly `10^27` units to its deployer, has 18 decimals and the requested name/symbol, and implements ordinary transfer/allowance behavior. It has no mint, burn, transfer-tax, NFT integration, or owner path. The eventual NFT reward contract must be separately funded from the requester's launch allocation.

The constructor validates the deployed address against the declared permissions. The required mask is 8396 (`0x20cc`): beforeInitialize, beforeSwap, afterSwap and both swap return-delta permissions. Salt prediction includes the constructor arguments and creation-code hash. The manifest uses `kind: univ4_hook`, names `DroneHook` itself, and supplies `$poolManager` and `$token` directly. The optional helper uses ordinary `new ... {salt: ...}`; no delegated execution is present in authored production source. Runtime opcode tests skip PUSH immediates and cover the hook, token and deployment/mining helper.

## Verification evidence and limits

The reviewer independently ran:

```text
forge test --match-contract IndependentQuoteReview -vv
2 tests passed; 0 failed; 0 skipped.
Differential fuzz test: 256 cases.
```

These review probes use the real vendored PoolManager, separately quote and execute a pool without a hook, and compare actual specified-currency deltas. Coverage includes both directions, exact input/output, overlapping initialized positions, zero-liquidity gaps, varied price limits and independent nonzero protocol fee settings for both directions. A second test establishes R-01 rather than concealing it. The implementation agent promoted these independently authored probes into the delivered `test/SpecifiedAmount.t.sol`.

The implementation suite additionally checks fee schedule endpoints, all four swap modes and both IMD currency orderings, partial fills, fresh-manager DRONE-only liquidity, sweeps and transfer failure, reentrancy, permission bits, immutable runtime opcodes, and fixed-supply token behavior. Final build and full-suite results are recorded separately by the implementation agent.

The implementation agent reported a successful 2/2-test mainnet fork run against the real manager and real IMD using:

```text
forge test --match-contract MainnetForkTest --fork-url https://ethereum-rpc.publicnode.com --fork-block-number 26140740 -vv
```

Pinned block: 26140740; reported block hash: `0xf7b639605d5d3d939a29b7b3bdbf02f606593fa4e202b4503f5803db459766a2`. Fork coverage includes all four swap modes along the opening curve, limited fills, and keeper payout. The tests provision the test wallet's IMD balance with a Foundry cheatcode; this is a simulated fork rehearsal, not evidence of a funded production launch. The review agent inspected the fork test source but did not separately re-run that network command. The default offline run intentionally skips fork tests; a skip is not a successful fork test.

Slither, Mythril, symbolic execution and formal verification were not performed. Review probes are not a proof for every reachable tick/liquidity state or arithmetic input. This review does not validate a launch platform's unavailable manifest schema beyond the supplied discriminator and inspected fields, choose the economic launch price, attest future on-chain code, or replace a professional external audit.

## Release responsibilities

1. Run the full offline build/tests with pinned Solidity 0.8.26 and record a successful mainnet fork against the real manager and IMD. Independently verify configured chain addresses/code and the exact production constructor arguments.
2. Confirm initial price, liquidity, requester allocation and funding for the later reward contract. The supplied 1:1 minor-unit initial price is an assumption, not an economic recommendation.
3. Mine with the exact factory address and final compiler output; verify the resulting permissions and deployed runtime; deploy and initialize atomically. Publish source verification and actual deployment identifiers after deployment.
4. Publish this report with the final reviewed sources and preserve the disclosed integer/gas limitations in operational documentation. Obtain the network's separate independent contributor review before releasing funded contracts. This AI peer review does not claim to complete that external network review or a human security audit.
5. Anyone can call `sweep`, but someone must pay its gas. Monitor accrued claims and make periodic keeper payouts; no privileged keeper operation is required.
