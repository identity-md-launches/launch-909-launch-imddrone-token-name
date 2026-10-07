// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {HookFixture} from "./helpers/HookFixture.sol";
import {TestRouter} from "./helpers/TestRouter.sol";
import {AdversarialRouter} from "./helpers/AdversarialRouter.sol";
import {DroneHook} from "../src/DroneHook.sol";
import {DroneToken} from "../src/DroneToken.sol";
import {MockERC20} from "./mocks/MockERC20.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {SwapParams, ModifyLiquidityParams} from "v4-core/src/types/PoolOperation.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";

/// @notice Multi-actor handler. Three traders through two routers, an LP who adds and removes
/// narrow positions so the quoter crosses initialized ticks, a donor who sends IMD straight to the
/// hook, a protocol-fee controller who changes the pool's protocol fee, time, and sweeps from
/// random callers. Every trade is checked against the brief's fee formula as it happens; ghost
/// variables carry what the hook must then hold.
contract DroneMultiActorHandler is Test {
    using StateLibrary for IPoolManager;

    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    DroneHook public immutable hook;
    IPoolManager public immutable manager;
    MockERC20 public immutable imd;
    DroneToken public immutable drone;
    TestRouter public immutable router;
    AdversarialRouter public immutable router2;
    PoolKey internal key;
    bool internal immutable imd0;

    address[3] public traders;
    address public lp;
    address public donor;
    address[6] public sweepers;
    int24[2][5] internal bands;
    int256[5] public lpLiquidity;

    uint256 public immutable ghostOpenedAt;
    uint256 public ghostFees;
    uint256 public ghostDonations;
    uint256 public ghostKeeperLast;
    uint256 public ghostLastRate;
    uint256 public trades;
    uint256 public sweeps;
    uint256 public skippedTrades;

    constructor(DroneHook h, IPoolManager m, TestRouter r, AdversarialRouter r2, PoolKey memory k) {
        hook = h;
        manager = m;
        router = r;
        router2 = r2;
        key = k;
        imd = MockERC20(Currency.unwrap(h.imd()));
        drone = DroneToken(h.token());
        imd0 = k.currency0 == h.imd();
        ghostOpenedAt = h.openedAt();
        ghostLastRate = 4000;
        traders = [makeAddr("trader0"), makeAddr("trader1"), makeAddr("trader2")];
        lp = makeAddr("lp");
        donor = makeAddr("donor");
        sweepers = [traders[0], lp, donor, h.keeper(), address(m), makeAddr("stranger")];
        bands[0] = [int24(-120), int24(120)];
        bands[1] = [int24(-300), int24(300)];
        bands[2] = [int24(-1200), int24(1200)];
        bands[3] = [int24(600), int24(1800)];
        bands[4] = [int24(-1800), int24(-600)];
    }

    function actors() external view returns (address[5] memory a) {
        a = [traders[0], traders[1], traders[2], lp, donor];
    }

    function approveAll() external {
        address[5] memory a = [traders[0], traders[1], traders[2], lp, donor];
        for (uint256 i; i < a.length; ++i) {
            vm.startPrank(a[i]);
            imd.approve(address(router), type(uint256).max);
            drone.approve(address(router), type(uint256).max);
            imd.approve(address(router2), type(uint256).max);
            drone.approve(address(router2), type(uint256).max);
            vm.stopPrank();
        }
    }

    function _rate() internal view returns (uint256) {
        if (block.timestamp <= ghostOpenedAt) return 4000;
        uint256 elapsed = block.timestamp - ghostOpenedAt;
        if (elapsed >= 3600) return 300;
        return 300 + (3700 * (3600 - elapsed)) / 3600;
    }

    function trade(uint8 who, uint96 size, bool buy, bool exactIn, bool limited, bool second, bytes32 data)
        external
    {
        address trader = traders[who % 3];
        uint256 amount = bound(size, 1, 1e21);
        SwapParams memory p;
        p.zeroForOne = buy == imd0;
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        (uint160 price, int24 tick,,) = manager.getSlot0(key.toId());
        if (limited) {
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(tick + (p.zeroForOne ? int24(-3) : int24(3)));
        } else {
            p.sqrtPriceLimitX96 = p.zeroForOne ? TickMath.MIN_SQRT_PRICE + 1 : TickMath.MAX_SQRT_PRICE - 1;
        }
        if (p.zeroForOne ? p.sqrtPriceLimitX96 >= price : p.sqrtPriceLimitX96 <= price) {
            ++skippedTrades;
            return;
        }
        uint256 rate = _rate();
        uint256 collectedBefore = hook.collected();
        uint256 pendingBefore = hook.pending();
        uint256 traderIMD = imd.balanceOf(trader);
        uint256 traderDrone = drone.balanceOf(trader);
        vm.recordLogs();
        vm.prank(trader);
        BalanceDelta result = second ? router2.swap(key, p, abi.encode(data, trader)) : router.swap(key, p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        int256 rawIMD;
        int256 rawDrone;
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter != address(manager) || logs[i].topics[0] != SWAP_EVENT) continue;
            (int128 a, int128 b,,,, uint24 swapFee) =
                abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
            assertGe(swapFee, 12500, "LP fee lowered");
            (rawIMD, rawDrone) = imd0 ? (int256(a), int256(b)) : (int256(b), int256(a));
        }
        int256 netIMD = imd0 ? int256(result.amount0()) : int256(result.amount1());
        int256 netDrone = imd0 ? int256(result.amount1()) : int256(result.amount0());
        uint256 fee = hook.collected() - collectedBefore;
        assertEq(netDrone, rawDrone, "fee taken in DRONE");
        assertEq(netIMD, rawIMD - int256(fee), "hook moved something other than its IMD fee");
        uint256 gross = buy ? uint256(-netIMD) : uint256(rawIMD);
        assertEq(fee, gross * rate / 10_000, "fee is not the scheduled share of gross IMD");
        assertEq(hook.pending() - pendingBefore, fee, "claim does not match the fee");
        assertEq(int256(imd.balanceOf(trader)) - int256(traderIMD), netIMD, "trader IMD delta");
        assertEq(int256(drone.balanceOf(trader)) - int256(traderDrone), netDrone, "trader DRONE delta");
        ghostFees += fee;
        ++trades;
    }

    function passTime(uint16 seconds_) external {
        vm.warp(block.timestamp + bound(seconds_, 0, 900));
        uint256 rate = hook.feeNow();
        assertLe(rate, ghostLastRate, "fee rate rose with time");
        ghostLastRate = rate;
    }

    function sweep(uint8 who) external {
        address caller = sweepers[who % 6];
        uint256 pending = hook.pending();
        uint256 claims = manager.balanceOf(address(hook), Currency.wrap(address(imd)).toId());
        uint256 keeperBefore = imd.balanceOf(hook.keeper());
        uint256 callerBefore = imd.balanceOf(caller);
        vm.prank(caller);
        uint256 swept = hook.sweep();
        assertEq(swept, pending, "sweep did not pay everything pending");
        assertEq(imd.balanceOf(hook.keeper()) - keeperBefore, pending, "keeper short-changed");
        if (caller == address(manager)) {
            assertEq(
                callerBefore - imd.balanceOf(caller), claims, "manager released more or less than the claims"
            );
        } else if (caller != hook.keeper()) {
            assertEq(imd.balanceOf(caller), callerBefore, "caller was paid");
        }
        assertEq(hook.pending(), 0, "pending after sweep");
        ++sweeps;
    }

    function addLiquidity(uint8 band, uint96 liq) external {
        uint256 b = band % 5;
        int256 liquidity = int256(uint256(bound(liq, 1e18, 1e24)));
        vm.prank(lp);
        router2.modifyLiquidity(key, ModifyLiquidityParams(bands[b][0], bands[b][1], liquidity, bytes32(0)));
        lpLiquidity[b] += liquidity;
    }

    function removeLiquidity(uint8 band, uint96 liq) external {
        uint256 b = band % 5;
        if (lpLiquidity[b] == 0) return;
        int256 liquidity = int256(bound(uint256(liq), 1, uint256(lpLiquidity[b])));
        vm.prank(lp);
        router2.modifyLiquidity(key, ModifyLiquidityParams(bands[b][0], bands[b][1], -liquidity, bytes32(0)));
        lpLiquidity[b] -= liquidity;
    }

    function donate(uint96 amount) external {
        uint256 a = bound(amount, 1, 1e21);
        vm.prank(donor);
        imd.transfer(address(hook), a);
        ghostDonations += a;
    }

    function setProtocolFee(uint16 zeroForOne, uint16 oneForZero) external {
        uint24 p0 = uint24(bound(zeroForOne, 0, 1000));
        uint24 p1 = uint24(bound(oneForZero, 0, 1000));
        manager.setProtocolFee(key, p0 | (p1 << 12));
    }
}

/// @notice Stateful properties over random call sequences. The hook holds value (IMD claims and
/// loose IMD), so what it holds must always equal what it owes the keeper, and the keeper must be
/// the only address that ever receives any of it.
contract DroneHookInvariantsTest is HookFixture {
    using StateLibrary for IPoolManager;

    DroneMultiActorHandler internal handler;
    AdversarialRouter internal router2;
    uint256 internal imdId;
    uint256 internal droneId;

    function setUp() public override {
        super.setUp();
        router2 = new AdversarialRouter(manager);
        handler = new DroneMultiActorHandler(hook, manager, router, router2, key);
        manager.setProtocolFeeController(address(handler));
        address[5] memory actors = handler.actors();
        for (uint256 i; i < actors.length; ++i) {
            imd.transfer(actors[i], 1e26);
            drone.transfer(actors[i], 1e26);
        }
        handler.approveAll();
        imdId = Currency.wrap(address(imd)).toId();
        droneId = Currency.wrap(address(drone)).toId();
        bytes4[] memory selectors = new bytes4[](7);
        selectors[0] = DroneMultiActorHandler.trade.selector;
        selectors[1] = DroneMultiActorHandler.passTime.selector;
        selectors[2] = DroneMultiActorHandler.sweep.selector;
        selectors[3] = DroneMultiActorHandler.addLiquidity.selector;
        selectors[4] = DroneMultiActorHandler.removeLiquidity.selector;
        selectors[5] = DroneMultiActorHandler.donate.selector;
        selectors[6] = DroneMultiActorHandler.setProtocolFee.selector;
        targetSelector(FuzzSelector(address(handler), selectors));
        targetContract(address(handler));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_collectedIsExactlyTheSumOfScheduledFees() public view {
        assertEq(hook.collected(), handler.ghostFees());
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_whatTheHookHoldsPlusWhatTheKeeperGotIsEverythingEverTaken() public view {
        assertEq(hook.pending() + imd.balanceOf(hook.keeper()), hook.collected() + handler.ghostDonations());
        assertEq(hook.pending(), manager.balanceOf(address(hook), imdId) + imd.balanceOf(address(hook)));
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_managerCanAlwaysHonourTheHooksClaims() public view {
        assertGe(imd.balanceOf(address(manager)), manager.balanceOf(address(hook), imdId));
        assertEq(manager.balanceOf(address(hook), droneId), 0, "DRONE claim minted to the hook");
        assertEq(drone.balanceOf(address(hook)), 0);
        assertEq(drone.balanceOf(hook.keeper()), 0);
        assertEq(drone.totalSupply(), 1e27);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_noIMDLeaksToAnyoneButTheKeeper() public view {
        address[5] memory actors = handler.actors();
        uint256 known = imd.balanceOf(address(this)) + imd.balanceOf(address(manager))
            + imd.balanceOf(address(hook)) + imd.balanceOf(hook.keeper());
        for (uint256 i; i < actors.length; ++i) {
            known += imd.balanceOf(actors[i]);
        }
        assertEq(known, imd.totalSupply(), "IMD reached an address nobody in this system is");
        assertEq(imd.balanceOf(address(router)), 0);
        assertEq(imd.balanceOf(address(router2)), 0);
        assertEq(imd.balanceOf(address(deployer)), 0);
    }

    /// forge-config: default.invariant.runs = 128
    /// forge-config: default.invariant.depth = 48
    function invariant_scheduleAndPoolFeeAreFrozen() public view {
        assertEq(hook.openedAt(), handler.ghostOpenedAt());
        assertTrue(hook.initialized());
        uint256 rate = hook.feeNow();
        assertGe(rate, 300);
        assertLe(rate, 4000);
        if (block.timestamp >= hook.openedAt() + 3600) assertEq(rate, 300);
        (,,, uint24 lpFee) = manager.getSlot0(key.toId());
        assertEq(lpFee, 12500);
        assertEq(hook.keeper(), 0x086b47d05aAE785F871191c1198231E9e6033c64);
    }
}

contract DroneHookInvariantsIMDSecondTest is DroneHookInvariantsTest {
    function _imdFirst() internal pure override returns (bool) {
        return false;
    }
}
