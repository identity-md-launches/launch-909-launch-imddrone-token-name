// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {DroneHook} from "../src/DroneHook.sol";
import {HookFlags} from "../src/HookFlags.sol";
import {IPoolManager} from "v4-core/src/interfaces/IPoolManager.sol";

/// @notice Optional plain CREATE2 helper. The launch manifest deploys DroneHook directly.
/// @dev Does not hold tokens, read environment variables, broadcast, or execute delegated code.
contract DeployDrone {
    error InvalidSalt();
    error SaltNotFound();

    function initCodeHash(IPoolManager manager, address imd, address token) public pure returns (bytes32) {
        return keccak256(abi.encodePacked(type(DroneHook).creationCode, abi.encode(manager, imd, token)));
    }

    function predict(address deployer, bytes32 salt, bytes32 codeHash) public pure returns (address) {
        return address(uint160(uint256(keccak256(abi.encodePacked(bytes1(0xff), deployer, salt, codeHash)))));
    }

    /// @notice Bounded off-chain eth_call search; resume at start + count if no salt was found.
    function mine(address deployer, bytes32 codeHash, uint256 start, uint256 count)
        external
        pure
        returns (bytes32 salt, address predicted)
    {
        for (uint256 i; i < count; ++i) {
            salt = bytes32(start + i);
            predicted = predict(deployer, salt, codeHash);
            if (HookFlags.matches(predicted, HookFlags.DRONE)) return (salt, predicted);
        }
        revert SaltNotFound();
    }

    function deploy(IPoolManager manager, address imd, address token, bytes32 salt)
        external
        returns (DroneHook)
    {
        if (!HookFlags.matches(
                predict(address(this), salt, initCodeHash(manager, imd, token)), HookFlags.DRONE
            )) {
            revert InvalidSalt();
        }
        return new DroneHook{salt: salt}(manager, imd, token);
    }
}
