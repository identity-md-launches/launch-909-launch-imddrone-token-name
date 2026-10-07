// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {AdversarialRouter} from "./helpers/AdversarialRouter.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";

/// @notice Mainnet rehearsal that runs at whatever block the fork provides. The accepted suite pins
/// block 26140740, which public non-archive nodes stop serving within hours; this one only needs a
/// recent block, so the rehearsal can be repeated before release:
///
///   forge test --match-contract MainnetForkRecentTest --fork-url <mainnet rpc> -vv
///
/// Skipped, never passed, without a mainnet fork. No environment variables are read.
contract MainnetForkRecentTest is HookFixture {
    using StateLibrary for IPoolManager;

    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    AdversarialRouter internal adversary;
    address internal alice = makeAddr("alice");

    function setUp() public override {
        if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0 || MAINNET_IMD.code.length == 0) {
            vm.skip(true);
            return;
        }
        manager = IPoolManager(MAINNET_MANAGER);
        imd = MockERC20(MAINNET_IMD);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        drone = new DroneToken();
        deal(MAINNET_IMD, address(this), 1e27);
        deal(MAINNET_IMD, alice, 1e24);
        _setupHook();
        adversary = new AdversarialRouter(manager);
        imd.approve(address(adversary), type(uint256).max);
        drone.approve(address(adversary), type(uint256).max);
        drone.transfer(alice, 1e24);
        vm.startPrank(alice);
        imd.approve(address(router), type(uint256).max);
        drone.approve(address(router), type(uint256).max);
        imd.approve(address(adversary), type(uint256).max);
        drone.approve(address(adversary), type(uint256).max);
        vm.stopPrank();
        router.seed(key, -600, 600, 1e25);
    }

    function test_mainnetHookAddressAndOpening() public view {
        assertTrue(HookFlags.matches(address(hook), HookFlags.DRONE));
        assertEq(hook.openedAt(), block.timestamp);
        assertEq(hook.feeNow(), 4000);
        assertEq(address(hook.poolManager()), MAINNET_MANAGER);
        assertEq(Currency.unwrap(hook.imd()), MAINNET_IMD);
        assertEq(address(drone) < MAINNET_IMD, key.currency0 == Currency.wrap(address(drone)));
    }

    function test_mainnetBuyAndSellAlongTheCurveThenSweep() public {
        uint256 opened = hook.openedAt();
        uint256[4] memory offsets = [uint256(0), 900, 3599, 3600];
        for (uint256 t; t < offsets.length; ++t) {
            vm.warp(opened + offsets[t]);
            _checkedSwap(true, true, 1e18, false);
            _checkedSwap(true, false, 1e18, false);
            _checkedSwap(false, true, 1e18, false);
            _checkedSwap(false, false, 1e18, false);
        }
        assertEq(hook.feeNow(), 300);
        uint256 pending = hook.pending();
        uint256 before = imd.balanceOf(hook.keeper());
        vm.prank(alice);
        assertEq(hook.sweep(), pending);
        assertEq(imd.balanceOf(hook.keeper()) - before, pending, "real IMD moved a different amount");
        assertEq(hook.pending(), 0);
        assertEq(hook.sweep(), 0);
    }

    function test_mainnetPartialFillsAndSecondTrader() public {
        _checkedSwap(true, true, 1e23, true);
        _checkedSwap(false, false, 1e23, true);
        uint256 before = hook.collected();
        SwapParams memory p = _params(true, false, 1e18, false);
        vm.prank(alice);
        adversary.swap(key, p, hex"deadbeef");
        assertGt(hook.collected(), before);
        p = _params(false, true, 1e18, false);
        vm.prank(alice);
        router.swap(key, p);
        assertEq(hook.pending(), hook.collected());
    }

    function test_mainnetFailedSwapLeavesNothingBehind() public {
        _checkedSwap(true, true, 1e20, false);
        uint256 collected = hook.collected();
        SwapParams memory p = _params(false, true, 1e18, false);
        vm.expectRevert(IPoolManager.CurrencyNotSettled.selector);
        adversary.swapWithoutSettling(key, p);
        assertEq(hook.collected(), collected);
        assertEq(hook.pending(), collected);
    }
}
