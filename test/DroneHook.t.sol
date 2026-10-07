// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {DroneHook} from "../src/DroneHook.sol";
import {DeployDrone} from "../script/DeployDrone.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {Hooks} from "v4-core/src/libraries/Hooks.sol";

contract DroneHookTest is HookFixture {
    function test_scheduleEndpointsAndEverySecond() public {
        assertEq(hook.openedAt(), 10_000);
        assertEq(hook.keeper(), 0x086b47d05aAE785F871191c1198231E9e6033c64);
        for (uint256 t; t <= 3600; ++t) {
            vm.warp(10_000 + t);
            assertEq(hook.feeNow(), 300 + (3700 * (3600 - t)) / 3600);
        }
        vm.warp(type(uint64).max);
        assertEq(hook.feeNow(), 300);
    }

    function test_allModesAtOpeningMidpointAndAfterHour() public {
        uint256[5] memory times = [uint256(0), 1, 1800, 3600, 86400];
        for (uint256 t; t < times.length; ++t) {
            vm.warp(10_000 + times[t]);
            _checkedSwap(true, true, 1e18, false);
            _checkedSwap(true, false, 1e18, false);
            _checkedSwap(false, true, 1e18, false);
            _checkedSwap(false, false, 1e18, false);
        }
    }

    function testFuzz_feeAndPartialFills(bool buy, bool exactIn, uint96 size, uint32 time, bool limited)
        public
    {
        vm.warp(10_000 + bound(time, 0, 7200));
        uint256 amount = bound(size, 1, 1e25);
        _checkedSwap(buy, exactIn, amount, limited);
    }

    function testFuzz_crossTicksAndEmptyLiquidity(bool buy, bool exactIn, uint96 size, uint16 time) public {
        router.seed(key, -120, 120, 1e25);
        router.seed(key, -360, 360, 1e25);
        vm.warp(10_000 + bound(time, 0, 7200));
        _checkedSwap(buy, exactIn, bound(size, 1e24, 9e26), false);
    }

    function test_partialFillsAllModes() public {
        for (uint256 t; t < 2; ++t) {
            vm.warp(10_000 + t * 3600);
            _checkedSwap(true, true, 1e25, true);
            _checkedSwap(true, false, 1e25, true);
            _checkedSwap(false, true, 1e25, true);
            _checkedSwap(false, false, 1e25, true);
        }
    }

    function test_tinyAmountsAndHugePartialRequests() public {
        for (uint256 n = 1; n <= 12; ++n) {
            _checkedSwap(true, true, n, false);
            _checkedSwap(false, false, n, false);
        }
        _checkedSwap(true, true, uint256(type(int256).max), true);
        _checkedSwap(false, false, uint256(type(int256).max) - 1e38, true);
    }

    function test_sweepAnyoneRepeatedAndDirectDonations() public {
        _checkedSwap(true, true, 1e20, false);
        _checkedSwap(false, true, 1e18, false);
        uint256 fees = hook.collected();
        imd.transfer(address(hook), 123);
        uint256 before = imd.balanceOf(hook.keeper());
        vm.prank(address(0xBEEF));
        assertEq(hook.sweep(), fees + 123);
        assertEq(imd.balanceOf(hook.keeper()), before + fees + 123);
        assertEq(hook.pending(), 0);
        assertEq(hook.collected(), fees);
        assertEq(hook.sweep(), 0);
        _checkedSwap(true, false, 1e18, false);
        assertGt(hook.sweep(), 0);
        assertEq(hook.pending(), 0);
    }

    function test_reentrantSweepCannotRedirectOrDoublePay() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 fees = hook.pending();
        imd.configure(address(hook), false);
        hook.sweep();
        assertTrue(imd.didReenter());
        assertTrue(imd.reentrySucceeded(), "nested sweep is harmless no-op");
        assertEq(imd.balanceOf(hook.keeper()), fees);
        assertEq(hook.pending(), 0);
    }

    function test_failedSweepRollsBackAndDoesNotPoisonTrading() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 fees = hook.pending();
        imd.configure(address(0), true);
        vm.expectRevert();
        hook.sweep();
        assertEq(hook.pending(), fees);
        imd.configure(address(0), false);
        _checkedSwap(false, false, 1e18, false);
        assertGt(hook.sweep(), fees);
    }

    function test_noLiquidityCollectsNoFee() public {
        router.seed(key, -600, 600, -1e27);
        assertEq(_checkedSwap(true, true, 1e18, true), 0);
        assertEq(_checkedSwap(true, false, 1e18, true), 0);
        assertEq(_checkedSwap(false, true, 1e18, true), 0);
        assertEq(_checkedSwap(false, false, 1e18, true), 0);
        assertEq(hook.collected(), 0);
    }

    function test_reentrancyFromSwapTransferDefersSweep() public {
        _checkedSwap(true, true, 1e20, false);
        imd.configure(address(hook), false);
        _checkedSwap(false, true, 1e18, false);
        assertTrue(imd.didReenter());
        assertTrue(imd.reentrySucceeded());
        assertEq(imd.balanceOf(hook.keeper()), 0);
        assertEq(hook.pending(), hook.collected());
        hook.sweep();
        assertEq(hook.pending(), 0);
    }

    function test_sweepDuringUnlockDefersWithoutReverting() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 fees = hook.pending();
        router.sweepDuringUnlock(key);
        assertEq(hook.pending(), fees);
        hook.sweep();
        assertEq(hook.pending(), 0);
    }

    function test_callbacksOnlyManager() public {
        vm.expectRevert(DroneHook.OnlyPoolManager.selector);
        hook.beforeInitialize(address(this), key, ONE);
        SwapParams memory p = _params(true, true, 1e18, false);
        vm.expectRevert(DroneHook.OnlyPoolManager.selector);
        hook.beforeSwap(address(this), key, p, "");
        vm.expectRevert(DroneHook.OnlyPoolManager.selector);
        hook.afterSwap(address(this), key, p, BalanceDelta.wrap(0), "");
        vm.expectRevert(DroneHook.OnlyPoolManager.selector);
        hook.unlockCallback("");
        vm.prank(address(manager));
        vm.expectRevert(DroneHook.UnexpectedUnlock.selector);
        hook.unlockCallback("");
    }

    function test_openingCannotBeResetOrReusedForAnotherPool() public {
        uint256 opened = hook.openedAt();
        PoolKey memory other = key;
        other.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(other, ONE);
        assertEq(hook.openedAt(), opened);
    }

    function test_permissionBitsAndNoEscapeOpcodes() public view {
        assertTrue(HookFlags.matches(address(hook), HookFlags.DRONE));
        Hooks.Permissions memory p = hook.getHookPermissions();
        assertTrue(
            p.beforeInitialize && p.beforeSwap && p.afterSwap && p.beforeSwapReturnDelta
                && p.afterSwapReturnDelta
        );
        assertFalse(
            p.afterInitialize || p.beforeAddLiquidity || p.afterAddLiquidity || p.beforeRemoveLiquidity
                || p.afterRemoveLiquidity || p.beforeDonate || p.afterDonate || p.afterAddLiquidityReturnDelta
                || p.afterRemoveLiquidityReturnDelta
        );
        _noEscape(address(hook).code);
        _noEscape(address(drone).code);
        _noEscape(address(deployer).code);
    }

    function _noEscape(bytes memory code) internal pure {
        for (uint256 i; i < code.length; ++i) {
            uint8 op = uint8(code[i]);
            if (op >= 0x60 && op <= 0x7f) {
                i += op - 0x5f;
                continue;
            }
            require(op != 0xf4 && op != 0xf2 && op != 0xff, "escape opcode");
        }
    }

    function test_initializationRejectsWrongPairFeeAndSpacing() public {
        DeployDrone helper = new DeployDrone();
        bytes32 hash = helper.initCodeHash(manager, address(imd), address(drone));
        (bytes32 salt,) = helper.mine(address(helper), hash, 0, 200_000);
        DroneHook fresh = helper.deploy(manager, address(imd), address(drone), salt);
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(fresh));
        candidate.fee = 0;
        vm.expectRevert();
        manager.initialize(candidate, ONE);
        candidate.fee = 0x800000;
        vm.expectRevert();
        manager.initialize(candidate, ONE);
        candidate.fee = 12500;
        candidate.tickSpacing = 120;
        vm.expectRevert();
        manager.initialize(candidate, ONE);
        candidate.tickSpacing = 60;
        Currency original = candidate.currency0;
        candidate.currency0 = Currency.wrap(address(1));
        vm.expectRevert();
        manager.initialize(candidate, ONE);
        candidate.currency0 = original;
        assertFalse(fresh.initialized());
        vm.warp(0);
        manager.initialize(candidate, ONE);
        assertTrue(fresh.initialized());
        assertEq(fresh.openedAt(), 0);
        vm.warp(3600);
        assertEq(fresh.feeNow(), 300);
    }

    function test_cannotInitializePredictedHookWithoutCode() public {
        PoolKey memory candidate = key;
        candidate.hooks = IHooks(address(uint160(0x100000) | HookFlags.DRONE));
        assertEq(address(candidate.hooks).code.length, 0);
        vm.expectRevert();
        manager.initialize(candidate, ONE);
    }

    function test_constructorRejectsZeroOrSameCurrencies() public {
        vm.expectRevert(DroneHook.InvalidConfiguration.selector);
        new DroneHook(IPoolManager(address(0)), address(imd), address(drone));
        vm.expectRevert(DroneHook.InvalidConfiguration.selector);
        new DroneHook(manager, address(imd), address(imd));
    }

    function test_invalidSaltRefused() public {
        bytes32 hash = deployer.initCodeHash(manager, address(imd), address(drone));
        uint256 salt;
        while (HookFlags.matches(deployer.predict(address(deployer), bytes32(salt), hash), HookFlags.DRONE)) {
            ++salt;
        }
        vm.expectRevert(DeployDrone.InvalidSalt.selector);
        deployer.deploy(manager, address(imd), address(drone), bytes32(salt));
    }

    function test_freshManagerWithDroneOnlyLiquidity() public {
        manager = IPoolManager(address(new PoolManager(address(this))));
        _setupHook();
        bool imd0 = key.currency0 == Currency.wrap(address(imd));
        router.seed(key, imd0 ? int24(-600) : int24(0), imd0 ? int24(0) : int24(600), 1e25);
        assertEq(imd.balanceOf(address(manager)), 0);
        _checkedSwap(true, true, 1e20, false);
        assertGt(hook.pending(), 0);
        hook.sweep();
        _checkedSwap(false, true, 1e18, false);
    }
}

contract DroneHookIMDSecondTest is DroneHookTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}
