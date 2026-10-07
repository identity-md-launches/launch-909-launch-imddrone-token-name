// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {AdversarialRouter} from "./helpers/AdversarialRouter.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {DroneHook} from "../src/DroneHook.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {DeployDrone} from "../script/DeployDrone.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IProtocolFees} from "v4-core/src/interfaces/IProtocolFees.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";
import {Pool} from "v4-core/src/libraries/Pool.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";

/// @notice Second-opinion suite written against the accepted implementation. Everything here is an
/// input the author's own suite did not reach: protocol fees on the hooked pool, walks to the tick
/// extremes, swaps that fail after the hook already ran, several swaps in one unlock, callers and
/// hook data the fee must ignore, and the constructor bytecode of every delivered contract.
contract DroneHookAdversarialTest is HookFixture {
    using StateLibrary for IPoolManager;

    AdversarialRouter internal adversary;
    address internal alice = makeAddr("alice");
    address internal bob = makeAddr("bob");

    function setUp() public virtual override {
        super.setUp();
        adversary = new AdversarialRouter(manager);
        imd.approve(address(adversary), type(uint256).max);
        drone.approve(address(adversary), type(uint256).max);
        _fund(alice, 1e24, 1e24);
        _fund(bob, 1e24, 1e24);
    }

    function _fund(address who, uint256 imdAmount, uint256 droneAmount) internal {
        imd.transfer(who, imdAmount);
        drone.transfer(who, droneAmount);
        vm.startPrank(who);
        imd.approve(address(router), type(uint256).max);
        drone.approve(address(router), type(uint256).max);
        imd.approve(address(adversary), type(uint256).max);
        drone.approve(address(adversary), type(uint256).max);
        vm.stopPrank();
    }

    function _imd0() internal view returns (bool) {
        return key.currency0 == Currency.wrap(address(imd));
    }

    /// @dev Independent oracle: the brief's fee on the gross IMD side of the trade. Gross IMD is what
    /// the trader paid in total on a buy and what the pool paid out before the hook on a sell.
    function _scheduledRate(uint256 at) internal view returns (uint256) {
        uint256 opened = hook.openedAt();
        if (at <= opened) return 4000;
        uint256 elapsed = at - opened;
        if (elapsed >= 3600) return 300;
        return 300 + (3700 * (3600 - elapsed)) / 3600;
    }

    // ---------------------------------------------------------------------------------------------
    // (1) exact scheduled fee under protocol fees the hook author did not configure
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 600
    function testFuzz_feeExactWithProtocolFeeOnHookedPool(
        bool buy,
        bool exactIn,
        uint96 size,
        uint32 time,
        bool limited,
        uint16 protocol0,
        uint16 protocol1
    ) public {
        uint24 p0 = uint24(bound(protocol0, 0, 1000));
        uint24 p1 = uint24(bound(protocol1, 0, 1000));
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, p0 | (p1 << 12));
        router.seed(key, -120, 120, 1e25);
        router.seed(key, -360, 360, 1e25);
        vm.warp(10_000 + bound(time, 0, 7200));
        _checkedSwap(buy, exactIn, bound(size, 1, 1e25), limited);
    }

    function test_protocolFeeMaximumBothDirectionsAllModes() public {
        manager.setProtocolFeeController(address(this));
        manager.setProtocolFee(key, 1000 | (1000 << 12));
        for (uint256 t; t < 3; ++t) {
            vm.warp(10_000 + t * 1800);
            _checkedSwap(true, true, 3e21, false);
            _checkedSwap(true, false, 3e21, false);
            _checkedSwap(false, true, 3e21, false);
            _checkedSwap(false, false, 3e21, false);
            _checkedSwap(true, true, 1e25, true);
            _checkedSwap(false, false, 1e25, true);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (1)(3) walks to the ends of the tick range: the quoter's MIN/MAX clamp path
    // ---------------------------------------------------------------------------------------------

    function _seedFullRange() internal {
        router.seed(key, -887220, 887220, 1e7);
    }

    function _extremeParams(bool buy, bool exactIn, uint256 amount)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = buy == _imd0();
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
    }

    function _extremeSwap(bool buy, bool exactIn, uint256 amount) internal returns (uint256 charged) {
        SwapParams memory p = _extremeParams(buy, exactIn, amount);
        uint256 before = hook.collected();
        vm.recordLogs();
        BalanceDelta result = router.swap(key, p);
        (int128 raw0, int128 raw1) = _rawSwap(vm.getRecordedLogs());
        int256 rawIMD = _imd0() ? int256(raw0) : int256(raw1);
        int256 rawDrone = _imd0() ? int256(raw1) : int256(raw0);
        int256 netIMD = _imd0() ? int256(result.amount0()) : int256(result.amount1());
        int256 netDrone = _imd0() ? int256(result.amount1()) : int256(result.amount0());
        charged = hook.collected() - before;
        assertEq(netDrone, rawDrone, "fee never in DRONE");
        assertEq(netIMD, rawIMD - int256(charged), "hook changed only the IMD side");
        uint256 gross = buy ? uint256(-netIMD) : uint256(rawIMD);
        assertEq(
            charged, gross * _scheduledRate(block.timestamp) / 10_000, "exact scheduled fee at the extreme"
        );
    }

    function test_walkToMaxAndMinPriceInBothDirections() public {
        _seedFullRange();
        // Sell DRONE for IMD until the price pins at the far end, exact input.
        _extremeSwap(false, true, 5e26);
        (uint160 price,,,) = manager.getSlot0(key.toId());
        bool sellIsZeroForOne = !_imd0();
        assertEq(
            price, sellIsZeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1, "pinned"
        );
        // Same direction again: the manager, not the hook, rejects it and the hook keeps no residue.
        uint256 collected = hook.collected();
        SwapParams memory again = _extremeParams(false, true, 1e18);
        vm.expectRevert();
        router.swap(key, again);
        assertEq(hook.collected(), collected);
        // Walk back across the whole range in the other direction with exact output larger than
        // everything the pool holds: the fill stops at the opposite extreme.
        vm.warp(10_000 + 1234);
        _extremeSwap(true, false, 1e27);
        (price,,,) = manager.getSlot0(key.toId());
        assertEq(
            price,
            sellIsZeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1,
            "pinned far side"
        );
        // And back once more with exact output IMD and exact input IMD after the opening hour.
        vm.warp(10_000 + 4000);
        _extremeSwap(false, false, 1e27);
        _extremeSwap(true, true, 4e26);
        hook.sweep();
        assertEq(hook.pending(), 0);
        assertEq(imd.balanceOf(hook.keeper()), hook.collected());
    }

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_extremeLimitsNeverLeaveTheFeeWrong(bool buy, bool exactIn, uint96 size, uint16 time)
        public
    {
        _seedFullRange();
        router.seed(key, 600, 15360, 1e20); // a position ending exactly on a bitmap word boundary
        router.seed(key, -15360, -600, 1e20);
        vm.warp(10_000 + bound(time, 0, 7200));
        _extremeSwap(buy, exactIn, bound(size, 1, 4e26));
    }

    // ---------------------------------------------------------------------------------------------
    // (3) failure paths: a swap that fails after the hook ran leaves nothing behind
    // ---------------------------------------------------------------------------------------------

    function test_failedSwapsLeaveNoFeeAccounting() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 collected = hook.collected();
        uint256 pending = hook.pending();

        address poor = makeAddr("poor");
        _fund(poor, 1e18, 1e18);
        // Exactly the pool's share but not the hook's: the input settlement fails after both callbacks.
        SwapParams memory p = _params(true, true, 1e18, false);
        vm.prank(poor);
        imd.transfer(address(1), 1); // one wei short of the requested exact input
        vm.prank(poor);
        vm.expectRevert();
        router.swap(key, p);

        // Exact output with insufficient IMD for the grossed-up input.
        p = _params(true, false, 1e18, false);
        vm.prank(poor);
        vm.expectRevert();
        router.swap(key, p);

        // The router refuses to settle after the swap.
        p = _params(false, true, 1e18, false);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        adversary.swapWithoutSettling(key, p);

        // Native parameter errors raised by the manager, not the hook.
        p = _params(true, true, 1e18, false);
        p.amountSpecified = 0;
        vm.expectRevert(IPoolManager.SwapAmountCannotBeZero.selector);
        router.swap(key, p);
        p = _params(true, true, 1e18, false);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MAX_SQRT_PRICE - 1 : TickMath.MIN_SQRT_PRICE + 1;
        vm.expectRevert();
        router.swap(key, p);
        p = _params(true, true, 1e18, false);
        p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE : TickMath.MAX_SQRT_PRICE;
        vm.expectRevert();
        router.swap(key, p);

        assertEq(hook.collected(), collected, "no fee survives a failed swap");
        assertEq(hook.pending(), pending, "no claim survives a failed swap");
        assertEq(manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId()), pending);
        _checkedSwap(true, true, 1e18, false);
        _checkedSwap(false, false, 1e18, false);
    }

    function test_exactOutputSellWithPoolTooShallowStopsAtLimitNotRevert() public {
        // Ask for more IMD than the pool can pay out before the limit, every mode, both schedules.
        for (uint256 t; t < 2; ++t) {
            vm.warp(10_000 + t * 3600);
            _checkedSwap(false, false, 1e26, true);
            _checkedSwap(true, false, 1e26, true);
            _checkedSwap(true, true, 1e26, true);
            _checkedSwap(false, true, 1e26, true);
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (6)/(1) the fee ignores who trades, through which router, and with what hook data
    // ---------------------------------------------------------------------------------------------

    /// forge-config: default.fuzz.runs = 300
    function testFuzz_feeIndependentOfCallerRouterAndHookData(
        bool buy,
        bool exactIn,
        uint96 size,
        uint32 time,
        bytes calldata hookData
    ) public {
        vm.warp(10_000 + bound(time, 0, 7200));
        uint256 amount = bound(size, 1, 1e22);
        SwapParams memory p = _params(buy, exactIn, amount, false);

        uint256 base = hook.collected();
        uint256 snapshot = vm.snapshotState();
        uint256 feeByOwner = _checkedSwap(buy, exactIn, amount, false);
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        vm.prank(alice);
        router.swap(key, p);
        uint256 feeByAlice = hook.collected() - base;
        assertTrue(vm.revertToState(snapshot));

        snapshot = vm.snapshotState();
        vm.prank(bob);
        adversary.swap(key, p, hookData);
        uint256 feeByBobWithData = hook.collected() - base;
        assertTrue(vm.revertToState(snapshot));

        _fund(hook.keeper(), 1e24, 1e24);
        vm.prank(hook.keeper());
        adversary.swap(key, p, abi.encode(address(0), type(uint256).max, hookData));
        uint256 feeByKeeper = hook.collected() - base;

        assertEq(feeByAlice, feeByOwner, "caller changes the fee");
        assertEq(feeByBobWithData, feeByOwner, "router or hook data changes the fee");
        assertEq(feeByKeeper, feeByOwner, "keeper is not privileged");
    }

    /// forge-config: default.fuzz.runs = 1000
    function testFuzz_scheduleIsMonotoneBoundedAndFlatAfterOneHour(uint32 a, uint32 b) public {
        uint256 opened = hook.openedAt();
        uint256 t1 = opened + bound(a, 0, 20_000);
        uint256 t2 = t1 + bound(b, 0, 20_000);
        vm.warp(t1);
        uint256 f1 = hook.feeNow();
        vm.warp(t2);
        uint256 f2 = hook.feeNow();
        assertLe(f2, f1, "fee rose with time");
        assertGe(f2, 300);
        assertLe(f1, 4000);
        if (t1 >= opened + 3600) assertEq(f1, 300);
        if (t2 >= opened + 3600) assertEq(f2, 300);
        if (t2 < opened + 3600) assertGt(f2, 300, "still in the opening window");
        // Linear: the drop over the window is proportional to the elapsed seconds, within rounding.
        if (t2 < opened + 3600) {
            uint256 expectedDrop = (3700 * (t2 - t1)) / 3600;
            assertApproxEqAbs(f1 - f2, expectedDrop, 1, "not linear in time");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (1)(5) several swaps in one unlock, with sweep poked in between
    // ---------------------------------------------------------------------------------------------

    function test_batchOfSwapsInOneUnlockChargesEachExactly() public {
        vm.warp(10_000 + 900);
        SwapParams[] memory ps = new SwapParams[](4);
        ps[0] = _params(true, true, 5e21, false);
        ps[1] = _params(false, true, 3e21, false);
        ps[2] = _params(true, false, 2e21, false);
        ps[3] = _params(false, false, 4e21, false);
        uint256 before = hook.collected();
        vm.recordLogs();
        BalanceDelta[] memory deltas = adversary.batch(key, ps);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        uint256 rate = _scheduledRate(block.timestamp);
        uint256 expectedTotal;
        uint256 seen;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            (int128 raw0, int128 raw1,,,, uint24 lp) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertEq(lp, 12500);
            int256 rawIMD = _imd0() ? int256(raw0) : int256(raw1);
            int256 netIMD = _imd0() ? int256(deltas[seen].amount0()) : int256(deltas[seen].amount1());
            bool buy = seen % 2 == 0;
            uint256 gross = buy ? uint256(-netIMD) : uint256(rawIMD);
            uint256 fee = uint256(rawIMD - netIMD);
            assertEq(fee, gross * rate / 10_000, "a swap inside a batch was charged differently");
            expectedTotal += fee;
            ++seen;
        }
        assertEq(seen, 4, "four swaps expected");
        assertEq(hook.collected() - before, expectedTotal, "collected is the sum of the batch's fees");
        assertEq(hook.pending(), hook.collected());
    }

    function test_sweepInsideAnotherUnlockDefersAndCallbacksRefuseIt() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 pending = hook.pending();
        SwapParams memory p = _params(false, true, 1e18, false);
        adversary.swapThenSweep(key, p);
        assertEq(adversary.sweptInsideUnlock(), 0, "sweep paid out while another unlock was open");
        assertGt(hook.pending(), pending, "the swap's own fee is still pending");
        assertEq(imd.balanceOf(hook.keeper()), 0);

        // Forged callbacks from inside a foreign unlock: the manager is unlocked, but the caller is not it.
        adversary.callHookInsideUnlock(
            key, abi.encodeWithSelector(DroneHook.unlockCallback.selector, bytes(""))
        );
        assertFalse(adversary.hookCallInsideUnlockSucceeded(), "unlockCallback accepted a stranger");
        adversary.callHookInsideUnlock(
            key, abi.encodeWithSelector(IHooks.beforeSwap.selector, address(this), key, p, bytes(""))
        );
        assertFalse(adversary.hookCallInsideUnlockSucceeded(), "beforeSwap accepted a stranger");
        adversary.callHookInsideUnlock(
            key,
            abi.encodeWithSelector(
                IHooks.afterSwap.selector, address(this), key, p, BalanceDelta.wrap(0), bytes("")
            )
        );
        assertFalse(adversary.hookCallInsideUnlockSucceeded(), "afterSwap accepted a stranger");
        assertEq(hook.pending(), hook.collected());
        assertEq(hook.sweep(), hook.collected());
        assertEq(imd.balanceOf(hook.keeper()), hook.collected());
    }

    // ---------------------------------------------------------------------------------------------
    // (4) sweep: any caller, any number of times, keeper only
    // ---------------------------------------------------------------------------------------------

    function test_sweepManyCallersManyRoundsOnlyKeeperGains() public {
        address[6] memory callers =
            [alice, bob, hook.keeper(), address(manager), address(router), makeAddr("stranger")];
        uint256 supply = imd.totalSupply();
        for (uint256 round; round < 6; ++round) {
            vm.warp(10_000 + round * 700);
            _checkedSwap(round % 2 == 0, round % 3 == 0, 1e19 * (round + 1), false);
            uint256 pending = hook.pending();
            uint256 keeperBefore = imd.balanceOf(hook.keeper());
            uint256 callerBefore = imd.balanceOf(callers[round]);
            vm.prank(callers[round]);
            uint256 swept = hook.sweep();
            assertEq(swept, pending);
            assertEq(imd.balanceOf(hook.keeper()) - keeperBefore, pending, "keeper paid in full");
            if (callers[round] == address(manager)) {
                assertEq(
                    callerBefore - imd.balanceOf(callers[round]),
                    pending,
                    "manager released exactly the claims"
                );
            } else if (callers[round] != hook.keeper()) {
                assertEq(imd.balanceOf(callers[round]), callerBefore, "caller paid");
            }
            assertEq(hook.pending(), 0);
            vm.prank(callers[(round + 1) % 6]);
            assertEq(hook.sweep(), 0, "second sweep pays nothing");
        }
        assertEq(imd.balanceOf(hook.keeper()), hook.collected(), "keeper holds exactly what was ever taken");
        assertEq(imd.totalSupply(), supply);
        assertEq(imd.balanceOf(address(hook)), 0);
    }

    // ---------------------------------------------------------------------------------------------
    // (6) address bits and bytecode of everything delivered, constructors included
    // ---------------------------------------------------------------------------------------------

    function test_constructorRefusesAnAddressWithoutTheFlags() public {
        // Plain CREATE lands on an address whose low bits are whatever the nonce says; the hook must refuse it.
        address predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        while (HookFlags.matches(predicted, HookFlags.DRONE)) {
            new DroneToken(); // burn a nonce until the prediction carries the wrong bits
            predicted = vm.computeCreateAddress(address(this), vm.getNonce(address(this)));
        }
        vm.expectRevert(abi.encodeWithSelector(Hooks.HookAddressNotValid.selector, predicted));
        new DroneHook(manager, address(imd), address(drone));
    }

    function test_minedAddressCarriesExactlyTheManifestMask() public view {
        assertEq(HookFlags.flagsOf(address(hook)), 0x20cc);
        assertEq(HookFlags.DRONE, 0x20cc);
        assertTrue(Hooks.isValidHookAddress(IHooks(address(hook)), 12500));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_INITIALIZE_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_ADD_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_REMOVE_LIQUIDITY_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.BEFORE_DONATE_FLAG));
        assertFalse(Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_ADD_LIQUIDITY_RETURNS_DELTA_FLAG));
        assertFalse(
            Hooks.hasPermission(IHooks(address(hook)), Hooks.AFTER_REMOVE_LIQUIDITY_RETURNS_DELTA_FLAG)
        );
    }

    function test_creationCodeHasNoDelegatecallEither() public pure {
        _noEscapeOpcodes(type(DroneHook).creationCode);
        _noEscapeOpcodes(type(DroneToken).creationCode);
        _noEscapeOpcodes(type(DeployDrone).creationCode);
    }

    function test_deployHelperIsNotAWrapperAndHoldsNothing() public {
        _checkedSwap(true, true, 1e20, false);
        hook.sweep();
        assertEq(imd.balanceOf(address(deployer)), 0);
        assertEq(drone.balanceOf(address(deployer)), 0);
        assertEq(manager.balanceOf(address(deployer), Currency.wrap(address(imd)).toId()), 0);
        // The helper has no authority: nothing it exposes touches a deployed hook.
        (bool ok,) = address(deployer).call(abi.encodeWithSignature("sweep()"));
        assertFalse(ok);
        (ok,) = address(deployer).call(abi.encodeWithSignature("setKeeper(address)", alice));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("setKeeper(address)", alice));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("transferOwnership(address)", alice));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("upgradeTo(address)", alice));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("pause()"));
        assertFalse(ok);
        (ok,) = address(hook).call(abi.encodeWithSignature("updateDynamicLPFee(uint24)", uint24(0)));
        assertFalse(ok);
        assertEq(hook.keeper(), 0x086b47d05aAE785F871191c1198231E9e6033c64);
    }

    function _noEscapeOpcodes(bytes memory code) internal pure {
        require(code.length > 0, "empty code");
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xf4, "DELEGATECALL");
            require(op != 0xf2, "CALLCODE");
            require(op != 0xff, "SELFDESTRUCT");
        }
    }

    // ---------------------------------------------------------------------------------------------
    // (2) liquidity-side neutrality: adding and removing liquidity never touches the hook
    // ---------------------------------------------------------------------------------------------

    function test_liquidityChangesNeverAccrueFees() public {
        uint256 collected = hook.collected();
        adversary.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, 1e24, bytes32(0)));
        adversary.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, -5e23, bytes32(0)));
        assertEq(hook.collected(), collected);
        assertEq(hook.pending(), collected);
        _checkedSwap(true, true, 1e21, false);
        adversary.modifyLiquidity(key, ModifyLiquidityParams(-120, 120, -5e23, bytes32(0)));
        assertEq(hook.pending(), hook.collected());
    }
}

contract DroneHookAdversarialIMDSecondTest is DroneHookAdversarialTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}
