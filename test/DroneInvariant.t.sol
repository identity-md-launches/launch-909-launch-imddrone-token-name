// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {DroneHook} from "../src/DroneHook.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract DroneHandler is Test {
    DroneHook public immutable hook;
    TestRouter public immutable router;
    PoolKey internal key;
    bool internal immutable imd0;

    constructor(DroneHook h, TestRouter r, PoolKey memory k) {
        hook = h;
        router = r;
        key = k;
        imd0 = k.currency0 == h.imd();
        MockERC20(Currency.unwrap(h.imd())).approve(address(r), type(uint256).max);
        DroneToken(h.token()).approve(address(r), type(uint256).max);
    }

    function trade(uint96 size, bool buy, bool exactIn) external {
        uint256 amount = bound(size, 1, 1e20);
        bool left = buy == imd0;
        router.swap(
            key,
            SwapParams(
                left,
                exactIn ? -int256(amount) : int256(amount),
                TickMath.getSqrtPriceAtTick(left ? int24(-1200) : int24(1200))
            )
        );
    }

    function passTime(uint16 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 600));
    }

    function sweep() external {
        hook.sweep();
    }
}

contract DroneInvariantTest is HookFixture {
    DroneHandler internal handler;

    function setUp() public override {
        super.setUp();
        handler = new DroneHandler(hook, router, key);
        imd.transfer(address(handler), 1e26);
        drone.transfer(address(handler), 1e26);
        bytes4[] memory selectors = new bytes4[](3);
        selectors[0] = DroneHandler.trade.selector;
        selectors[1] = DroneHandler.passTime.selector;
        selectors[2] = DroneHandler.sweep.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    function invariant_allCollectedIMDEitherPendingOrPaidOnlyToKeeper() public view {
        assertEq(hook.pending() + imd.balanceOf(hook.keeper()), hook.collected());
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    function invariant_tokenSupplyAndOpeningCannotChange() public view {
        assertEq(drone.totalSupply(), 1e27);
        assertEq(drone.balanceOf(address(hook)), 0);
        assertEq(drone.balanceOf(hook.keeper()), 0);
        assertEq(hook.openedAt(), 10_000);
        assertGe(hook.feeNow(), 300);
        assertLe(hook.feeNow(), 4000);
    }
}
