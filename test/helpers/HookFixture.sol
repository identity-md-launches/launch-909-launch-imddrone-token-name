// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {Test} from "forge-std/Test.sol";
import {Vm} from "forge-std/Vm.sol";
import {PoolManager} from "v4-core/src/PoolManager.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";
import {IHooks} from "v4-core/src/interfaces/IHooks.sol";
import {PoolKey} from "v4-core/src/types/PoolKey.sol";
import {Currency} from "v4-core/src/types/Currency.sol";
import {SwapParams} from "v4-core/src/types/PoolOperation.sol";
import {BalanceDelta} from "v4-core/src/types/BalanceDelta.sol";
import {StateLibrary} from "v4-core/src/libraries/StateLibrary.sol";
import {TickMath} from "v4-core/src/libraries/TickMath.sol";
import {ProtocolFeeLibrary} from "v4-core/src/libraries/ProtocolFeeLibrary.sol";
import {DroneToken} from "../../src/DroneToken.sol";
import {DroneHook} from "../../src/DroneHook.sol";
import {DeployDrone} from "../../script/DeployDrone.sol";
import {MockERC20} from "../mocks/MockERC20.sol";
import {TestRouter} from "./TestRouter.sol";

abstract contract HookFixture is Test {
    using StateLibrary for IPoolManager;
    IPoolManager internal manager;
    DroneToken internal drone;
    MockERC20 internal imd;
    DroneHook internal hook;
    DeployDrone internal deployer;
    TestRouter internal router;
    PoolKey internal key;
    uint160 internal constant ONE = 79228162514264337593543950336;
    bytes32 internal constant SWAP_EVENT =
        keccak256("Swap(bytes32,address,int128,int128,uint160,uint128,int24,uint24)");

    function _imdFirst() internal pure virtual returns (bool) {
        return true;
    }

    function setUp() public virtual {
        vm.warp(10_000);
        manager = IPoolManager(address(new PoolManager(address(this))));
        drone = new DroneToken();
        MockERC20 template = new MockERC20("IMD", "IMD", 0);
        address imdAt = _imdFirst() ? address(0x1000) : address(type(uint160).max - 1);
        vm.etch(imdAt, address(template).code);
        imd = MockERC20(imdAt);
        imd.mint(address(this), 1e30);
        _setupHook();
        router.seed(key, -600, 600, 1e27);
    }

    function _setupHook() internal {
        deployer = new DeployDrone();
        bytes32 hash = deployer.initCodeHash(manager, address(imd), address(drone));
        (bytes32 salt,) = deployer.mine(address(deployer), hash, 0, 200_000);
        hook = deployer.deploy(manager, address(imd), address(drone), salt);
        bool imd0 = address(imd) < address(drone);
        key = PoolKey(
            Currency.wrap(imd0 ? address(imd) : address(drone)),
            Currency.wrap(imd0 ? address(drone) : address(imd)),
            12500,
            60,
            IHooks(address(hook))
        );
        manager.initialize(key, ONE);
        router = new TestRouter(manager);
        imd.approve(address(router), type(uint256).max);
        drone.approve(address(router), type(uint256).max);
    }

    function _params(bool buy, bool exactIn, uint256 amount, bool limited)
        internal
        view
        returns (SwapParams memory p)
    {
        p.zeroForOne = buy == (key.currency0 == Currency.wrap(address(imd)));
        p.amountSpecified = exactIn ? -int256(amount) : int256(amount);
        if (limited) {
            (, int24 current,,) = manager.getSlot0(key.toId());
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(current + (p.zeroForOne ? int24(-1) : int24(2)));
        } else {
            p.sqrtPriceLimitX96 = TickMath.getSqrtPriceAtTick(p.zeroForOne ? int24(-1200) : int24(1200));
        }
    }

    function _checkedSwap(bool buy, bool exactIn, uint256 amount, bool limited)
        internal
        returns (uint256 charged)
    {
        SwapParams memory p = _params(buy, exactIn, amount, limited);
        uint256 beforeCollected = hook.collected();
        uint256 beforePending = hook.pending();
        uint256 beforeIMD = imd.balanceOf(address(this));
        uint256 beforeDrone = drone.balanceOf(address(this));
        vm.recordLogs();
        BalanceDelta result = router.swap(key, p);
        Vm.Log[] memory logs = vm.getRecordedLogs();
        (int128 raw0, int128 raw1) = _rawSwap(logs);
        bool imd0 = key.currency0 == Currency.wrap(address(imd));
        int256 rawIMD = imd0 ? int256(raw0) : int256(raw1);
        int256 rawDrone = imd0 ? int256(raw1) : int256(raw0);
        int256 netIMD = imd0 ? int256(result.amount0()) : int256(result.amount1());
        int256 netDrone = imd0 ? int256(result.amount1()) : int256(result.amount0());
        charged = hook.collected() - beforeCollected;
        assertEq(netDrone, rawDrone, "DRONE fee forbidden");
        assertEq(netIMD, rawIMD - int256(charged), "only IMD delta changed");
        uint256 gross = buy ? uint256(-netIMD) : uint256(rawIMD);
        assertEq(charged, gross * hook.feeNow() / 10_000, "exact scheduled fee on actual gross IMD");
        assertEq(hook.pending(), beforePending + charged, "claim conservation");
        assertEq(int256(imd.balanceOf(address(this))) - int256(beforeIMD), netIMD);
        assertEq(int256(drone.balanceOf(address(this))) - int256(beforeDrone), netDrone);
        assertLe(charged, gross * 4000 / 10_000);
        if (exactIn) assertLe(uint256(-(buy ? netIMD : netDrone)), amount);
        else assertLe(uint256(buy ? netDrone : netIMD), amount);
        if (!limited && amount <= 1e22) {
            if (exactIn) assertEq(uint256(-(buy ? netIMD : netDrone)), amount, "full exact input");
            else assertEq(uint256(buy ? netDrone : netIMD), amount, "full exact output");
        }
        (,,, uint24 lp) = manager.getSlot0(key.toId());
        assertEq(lp, 12500, "static LP fee unchanged");
    }

    function _rawSwap(Vm.Log[] memory logs) internal view returns (int128 a, int128 b) {
        for (uint256 i; i < logs.length; ++i) {
            if (logs[i].emitter == address(manager) && logs[i].topics[0] == SWAP_EVENT) {
                uint24 fee;
                (a, b,,,, fee) = abi.decode(logs[i].data, (int128, int128, uint160, uint128, int24, uint24));
                _assertSwapFeeIsStaticLpPlusProtocol(fee, a, b);
                return (a, b);
            }
        }
        revert("missing swap event");
    }

    /// @dev The Swap event carries the manager's combined swap fee: the static 12500 LP fee, or that LP
    /// fee composed with the directional protocol fee when one is set. A hook override would show up here.
    function _assertSwapFeeIsStaticLpPlusProtocol(uint24 fee, int128 amount0, int128 amount1) internal view {
        (,, uint24 protocolFee, uint24 lp) = manager.getSlot0(key.toId());
        assertEq(lp, 12500, "static LP fee unchanged");
        if (protocolFee == 0) {
            assertEq(fee, 12500, "manager's swap used static LP fee");
            return;
        }
        uint24 zeroForOneFee =
            ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getZeroForOneFee(protocolFee), lp);
        uint24 oneForZeroFee =
            ProtocolFeeLibrary.calculateSwapFee(ProtocolFeeLibrary.getOneForZeroFee(protocolFee), lp);
        if (amount0 == 0 && amount1 == 0) {
            assertTrue(fee == zeroForOneFee || fee == oneForZeroFee, "swap fee is not LP plus protocol");
        } else {
            bool zeroForOne = amount0 < 0 || amount1 > 0;
            assertEq(fee, zeroForOne ? zeroForOneFee : oneForZeroFee, "swap fee is not LP plus protocol");
        }
    }
}
