// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {DroneToken} from "../src/DroneToken.sol";

contract DroneTokenTest is Test {
    DroneToken token;

    function setUp() public {
        token = new DroneToken();
    }

    function test_fixedSupplyAndMetadata() public view {
        assertEq(token.name(), "imdDRONE");
        assertEq(token.symbol(), "DRONE");
        assertEq(token.decimals(), 18);
        assertEq(token.totalSupply(), 1e27);
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function testFuzz_ordinaryTransfersAndAllowances(uint96 raw) public {
        uint256 amount = bound(raw, 0, token.totalSupply());
        token.approve(address(0xBEEF), amount);
        vm.prank(address(0xBEEF));
        assertTrue(token.transferFrom(address(this), address(0xCAFE), amount));
        assertEq(token.allowance(address(this), address(0xBEEF)), 0);
        assertEq(token.balanceOf(address(0xCAFE)), amount);
        assertEq(token.balanceOf(address(this)), 1e27 - amount);
        assertEq(token.totalSupply(), 1e27);
        vm.prank(address(0xCAFE));
        assertTrue(token.transfer(address(this), amount));
        assertEq(token.balanceOf(address(this)), 1e27);
    }

    function test_zeroSelfTransfersAndInfiniteAllowance() public {
        token.transfer(address(0xCAFE), 0);
        token.transfer(address(this), 123);
        assertEq(token.balanceOf(address(this)), 1e27);
        token.approve(address(0xBEEF), type(uint256).max);
        vm.prank(address(0xBEEF));
        token.transferFrom(address(this), address(0xCAFE), 1);
        assertEq(token.allowance(address(this), address(0xBEEF)), type(uint256).max);
    }

    function test_failurePaths() public {
        vm.expectRevert(DroneToken.ZeroAddress.selector);
        token.transfer(address(0), 1);
        vm.expectRevert(DroneToken.ZeroAddress.selector);
        token.approve(address(0), 1);
        vm.expectRevert(DroneToken.InsufficientBalance.selector);
        token.transfer(address(1), 1e27 + 1);
        vm.prank(address(0xBEEF));
        vm.expectRevert(DroneToken.InsufficientAllowance.selector);
        token.transferFrom(address(this), address(1), 1);
    }

    function test_noAdminOrMintEvenForDeployer() public {
        string[9] memory signatures = [
            "mint(address,uint256)",
            "setOwner(address)",
            "transferOwnership(address)",
            "upgradeTo(address)",
            "initialize(address)",
            "pause()",
            "setTax(uint256)",
            "setMinter(address)",
            "burn(uint256)"
        ];
        for (uint256 i; i < signatures.length; ++i) {
            (bool ok,) = address(token).call(abi.encodeWithSignature(signatures[i], address(this), 1e27));
            assertFalse(ok);
            assertEq(token.totalSupply(), 1e27);
            assertEq(token.balanceOf(address(this)), 1e27);
        }
    }
}
