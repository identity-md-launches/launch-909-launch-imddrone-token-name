// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {SpecifiedAmount} from "../src/SpecifiedAmount.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

contract IndependentQuoteHarness {
    function filled(IPoolManager manager, PoolKey calldata key, SwapParams memory params)
        external
        view
        returns (uint256)
    {
        return SpecifiedAmount.filled(manager, key, params);
    }
}

contract IndependentQuoteReview is HookFixture {
    using StateLibrary for IPoolManager;
    IndependentQuoteHarness internal q;

    function setUp() public override {
        super.setUp();
        q = new IndependentQuoteHarness();
        key.hooks = IHooks(address(0));
        manager.initialize(key, ONE);
        // Narrow, overlapping positions, initialized ticks, and zero-liquidity gaps.
        router.seed(key, -60, 60, 1e25);
        router.seed(key, -180, 180, 1e24);
        router.seed(key, -720, -300, 2e24);
        router.seed(key, 300, 720, 3e24);
        manager.setProtocolFeeController(address(this));
    }

    function testFuzz_independentSpecifiedFillMatchesManager(
        bool left,
        bool exactIn,
        uint96 size,
        uint16 distance,
        uint16 protocolA,
        uint16 protocolB
    ) public {
        uint24 p0 = uint24(bound(protocolA, 0, 1000));
        uint24 p1 = uint24(bound(protocolB, 0, 1000));
        manager.setProtocolFee(key, p0 | (p1 << 12));
        uint256 magnitude = bound(size, 1, 9e26);
        int24 destination = int24(uint24(bound(distance, 1, 2400)));
        SwapParams memory p = SwapParams({
            zeroForOne: left,
            amountSpecified: exactIn ? -int256(magnitude) : int256(magnitude),
            sqrtPriceLimitX96: TickMath.getSqrtPriceAtTick(left ? -destination : destination)
        });
        uint256 quoted = q.filled(manager, key, p);
        BalanceDelta actual = router.swap(key, p);
        int256 specified = (exactIn == left) ? int256(actual.amount0()) : int256(actual.amount1());
        assertEq(quoted, specified < 0 ? uint256(-specified) : uint256(specified));
    }

    function test_nativeExactOutputInt256MaxCanPartiallyFillButHookedRequestOverflows() public {
        SwapParams memory p = _params(false, false, uint256(type(int256).max), true);
        BalanceDelta nativeResult = router.swap(key, p);
        assertGt(nativeResult.amount0(), 0);
        key.hooks = IHooks(address(hook));
        p = _params(false, false, uint256(type(int256).max), true);
        vm.expectRevert();
        router.swap(key, p);
    }
}
