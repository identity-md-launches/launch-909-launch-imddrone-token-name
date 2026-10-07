// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IUnlockCallback} from "v4-core/src/interfaces/callback/IUnlockCallback.sol";
import {IERC20Minimal} from "v4-core/src/interfaces/external/IERC20Minimal.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {DroneHook} from "../../src/DroneHook.sol";

/// @dev Test scaffolding only. A second, independent router so the hook is never judged through a
/// single integration. It forwards caller-chosen hookData, batches several swaps in one unlock,
/// can refuse to settle, and can poke the hook from inside the manager's unlock.
contract AdversarialRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    uint8 private constant SWAP = 0;
    uint8 private constant BATCH = 1;
    uint8 private constant SWAP_NO_SETTLE = 2;
    uint8 private constant SWAP_THEN_SWEEP = 3;
    uint8 private constant LIQUIDITY = 4;
    uint8 private constant CALL_HOOK_INSIDE_UNLOCK = 5;

    uint256 public sweptInsideUnlock;
    bool public hookCallInsideUnlockSucceeded;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory p, bytes memory hookData)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(SWAP, msg.sender, key, abi.encode(p, hookData))), (BalanceDelta)
        );
    }

    function batch(PoolKey memory key, SwapParams[] memory ps) external returns (BalanceDelta[] memory) {
        return
            abi.decode(manager.unlock(abi.encode(BATCH, msg.sender, key, abi.encode(ps))), (BalanceDelta[]));
    }

    /// @dev Performs the swap and returns without settling: the manager must revert the whole unlock.
    function swapWithoutSettling(PoolKey memory key, SwapParams memory p) external {
        manager.unlock(abi.encode(SWAP_NO_SETTLE, msg.sender, key, abi.encode(p, bytes(""))));
    }

    /// @dev Swaps, then calls sweep while the router's input is still unsettled.
    function swapThenSweep(PoolKey memory key, SwapParams memory p) external returns (BalanceDelta) {
        return abi.decode(
            manager.unlock(abi.encode(SWAP_THEN_SWEEP, msg.sender, key, abi.encode(p, bytes("")))),
            (BalanceDelta)
        );
    }

    function modifyLiquidity(PoolKey memory key, ModifyLiquidityParams memory p)
        external
        returns (BalanceDelta)
    {
        return abi.decode(
            manager.unlock(abi.encode(LIQUIDITY, msg.sender, key, abi.encode(p))), (BalanceDelta)
        );
    }

    /// @dev Calls an arbitrary selector on the hook from inside an unlock the router holds.
    function callHookInsideUnlock(PoolKey memory key, bytes memory data) external {
        manager.unlock(abi.encode(CALL_HOOK_INSIDE_UNLOCK, msg.sender, key, data));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory payload) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        if (action == SWAP || action == SWAP_NO_SETTLE || action == SWAP_THEN_SWEEP) {
            (SwapParams memory p, bytes memory hookData) = abi.decode(payload, (SwapParams, bytes));
            BalanceDelta delta = manager.swap(key, p, hookData);
            if (action == SWAP_NO_SETTLE) return "";
            if (action == SWAP_THEN_SWEEP) sweptInsideUnlock = DroneHook(address(key.hooks)).sweep();
            _settle(key.currency0, delta.amount0(), payer);
            _settle(key.currency1, delta.amount1(), payer);
            return abi.encode(delta);
        }
        if (action == BATCH) {
            SwapParams[] memory ps = abi.decode(payload, (SwapParams[]));
            BalanceDelta[] memory deltas = new BalanceDelta[](ps.length);
            int256 total0;
            int256 total1;
            for (uint256 i; i < ps.length; ++i) {
                deltas[i] = manager.swap(key, ps[i], "");
                total0 += deltas[i].amount0();
                total1 += deltas[i].amount1();
            }
            _settle(key.currency0, int128(total0), payer);
            _settle(key.currency1, int128(total1), payer);
            return abi.encode(deltas);
        }
        if (action == LIQUIDITY) {
            (BalanceDelta delta,) =
                manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
            _settle(key.currency0, delta.amount0(), payer);
            _settle(key.currency1, delta.amount1(), payer);
            return abi.encode(delta);
        }
        (hookCallInsideUnlockSucceeded,) = address(key.hooks).call(payload);
        return "";
    }

    function _settle(Currency c, int128 delta, address payer) private {
        if (delta < 0) {
            manager.sync(c);
            require(
                IERC20Minimal(Currency.unwrap(c))
                    .transferFrom(payer, address(manager), uint256(-int256(delta))),
                "transfer"
            );
            manager.settle();
        } else if (delta > 0) {
            manager.take(c, payer, uint128(delta));
        }
    }
}
