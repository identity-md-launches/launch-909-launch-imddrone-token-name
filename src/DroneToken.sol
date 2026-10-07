// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

/// @notice Fixed-supply, ordinary ERC-20. The launch factory receives the entire supply.
contract DroneToken {
    string public constant name = "imdDRONE";
    string public constant symbol = "DRONE";
    uint8 public constant decimals = 18;
    uint256 public constant totalSupply = 1_000_000_000 ether;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    error ZeroAddress();
    error InsufficientBalance();
    error InsufficientAllowance();

    event Transfer(address indexed from, address indexed to, uint256 value);
    event Approval(address indexed owner, address indexed spender, uint256 value);

    constructor() {
        balanceOf[msg.sender] = totalSupply;
        emit Transfer(address(0), msg.sender, totalSupply);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        if (spender == address(0)) revert ZeroAddress();
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 approved = allowance[from][msg.sender];
        if (approved != type(uint256).max) {
            if (approved < amount) revert InsufficientAllowance();
            unchecked {
                allowance[from][msg.sender] = approved - amount;
            }
        }
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) private {
        if (from == address(0) || to == address(0)) revert ZeroAddress();
        uint256 balance = balanceOf[from];
        if (balance < amount) revert InsufficientBalance();
        unchecked {
            balanceOf[from] = balance - amount;
            balanceOf[to] += amount;
        }
        emit Transfer(from, to, amount);
    }
}
