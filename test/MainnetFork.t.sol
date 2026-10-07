// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {HookFixture} from "./helpers/HookFixture.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Explicit fork suite. Run with CLI --fork-url and --fork-block-number 26140740.
/// Default offline suite reports SKIP, never a false passing fork test. No environment reads.
contract MainnetForkTest is HookFixture {
    address internal constant MAINNET_MANAGER = 0x000000000004444c5dc75cB358380D2e3dE08A90;
    address internal constant MAINNET_IMD = 0xD34a99Bc0f67aE1bbd63C660e6d0b0dd03E263B7;

    function setUp() public override {
        if (block.chainid != 1 || MAINNET_MANAGER.code.length == 0) {
            vm.skip(true);
            return;
        }
        assertEq(block.number, 26140740, "use the documented fork block");
        manager = IPoolManager(MAINNET_MANAGER);
        imd = MockERC20(MAINNET_IMD);
        assertEq(imd.symbol(), "IMD");
        assertEq(imd.decimals(), 18);
        drone = new DroneToken();
        deal(MAINNET_IMD, address(this), 1e28);
        _setupHook();
        router.seed(key, -600, 600, 1e25);
    }

    function test_mainnetAllSwapModesAndSweep() public {
        uint256 opened = hook.openedAt();
        for (uint256 t; t < 3; ++t) {
            vm.warp(opened + t * 1800);
            _checkedSwap(true, true, 1e18, false);
            _checkedSwap(true, false, 1e18, false);
            _checkedSwap(false, true, 1e18, false);
            _checkedSwap(false, false, 1e18, false);
        }
        uint256 pending = hook.pending();
        uint256 before = imd.balanceOf(hook.keeper());
        hook.sweep();
        assertEq(imd.balanceOf(hook.keeper()) - before, pending);
        assertEq(hook.pending(), 0);
    }

    function test_mainnetPartialFills() public {
        _checkedSwap(true, true, 1e23, true);
        _checkedSwap(true, false, 1e23, true);
        _checkedSwap(false, true, 1e23, true);
        _checkedSwap(false, false, 1e23, true);
    }
}
