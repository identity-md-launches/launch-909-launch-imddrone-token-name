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

/// @dev Test scaffolding only. Settles returned deltas, catching incorrect hook accounting.
contract TestRouter is IUnlockCallback {
    IPoolManager public immutable manager;

    constructor(IPoolManager m) {
        manager = m;
    }

    function swap(PoolKey memory key, SwapParams memory p) external returns (BalanceDelta) {
        return
            abi.decode(manager.unlock(abi.encode(uint8(0), msg.sender, key, abi.encode(p))), (BalanceDelta));
    }

    function seed(PoolKey memory key, int24 lower, int24 upper, int256 liquidity)
        external
        returns (BalanceDelta)
    {
        ModifyLiquidityParams memory p = ModifyLiquidityParams(lower, upper, liquidity, bytes32(0));
        return
            abi.decode(manager.unlock(abi.encode(uint8(1), msg.sender, key, abi.encode(p))), (BalanceDelta));
    }

    function sweepDuringUnlock(PoolKey memory key) external {
        manager.unlock(abi.encode(uint8(2), msg.sender, key, bytes("")));
    }

    function unlockCallback(bytes calldata data) external returns (bytes memory) {
        require(msg.sender == address(manager), "manager only");
        (uint8 action, address payer, PoolKey memory key, bytes memory payload) =
            abi.decode(data, (uint8, address, PoolKey, bytes));
        BalanceDelta delta;
        if (action == 0) {
            delta = manager.swap(key, abi.decode(payload, (SwapParams)), "");
        } else if (action == 1) {
            (delta,) = manager.modifyLiquidity(key, abi.decode(payload, (ModifyLiquidityParams)), "");
        } else {
            require(DroneHook(address(key.hooks)).sweep() == 0, "sweep must defer");
            return "";
        }
        _settle(key.currency0, delta.amount0(), payer);
        _settle(key.currency1, delta.amount1(), payer);
        return abi.encode(delta);
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
