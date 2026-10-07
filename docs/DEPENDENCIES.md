# Vendored dependencies

Dependencies are ordinary source files, not submodules. No package manager or download is needed to verify the submission. Application contracts, deployment helper, token, fee logic and fill traversal were written for this assignment. Standard Uniswap arithmetic, interfaces and state decoding are reused rather than changing the AMM.

| Directory | Upstream revision | Included scope | License |
|---|---|---|---|
| `lib/v4-core` | Uniswap/v4-core `46c6834698c48bc4a463a86d8420f4eb1d7f3b75` | `src` excluding upstream test contracts; repository licenses | BUSL-1.1 / MIT per-file; see included licenses/ |
| `lib/forge-std` | foundry-rs/forge-std v1.9.7, `77041d2ce690e692d6e03cc812b57d1ddaa4d505` | test library `src` and licenses | MIT / Apache-2.0 |
| `lib/solmate` | transmissions11/solmate `4b47a19038b798b4a33d9749d25e570443520647` | `src/auth/Owned.sol` and LICENSE, needed by test PoolManager | AGPL-3.0 file; see SPDX and LICENSE |

The vendored PoolManager is deployed only by local tests. Production uses the canonical supplied PoolManager. Its protocol-fee ownership is a pre-existing external dependency, not an administrative power in any launch contract. No external Solidity library linkage is required by the application: library functions used by the hook are internal and inlined.

Review references were the pinned eth-security, eth-addresses and uniswap-v4-security inputs supplied with the assignment. Their templated admin/allowlist recommendations do not apply to this immutable, address-neutral design.
