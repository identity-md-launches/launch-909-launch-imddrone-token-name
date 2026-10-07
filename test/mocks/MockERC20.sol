// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

contract MockERC20 {
    string public name;
    string public symbol;
    uint8 public constant decimals = 18;
    uint256 public totalSupply;
    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;
    address public reentryTarget;
    bool public failTransfers;
    bool public didReenter;
    bool public reentrySucceeded;

    constructor(string memory n, string memory s, uint256 supply) {
        name = n;
        symbol = s;
        mint(msg.sender, supply);
    }

    function mint(address to, uint256 amount) public {
        balanceOf[to] += amount;
        totalSupply += amount;
    }

    function configure(address target, bool fail) external {
        reentryTarget = target;
        failTransfers = fail;
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        if (failTransfers) return false;
        _move(msg.sender, to, amount);
        if (reentryTarget != address(0)) {
            didReenter = true;
            (reentrySucceeded,) = reentryTarget.call(abi.encodeWithSignature("sweep()"));
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        if (failTransfers) return false;
        if (allowance[from][msg.sender] != type(uint256).max) allowance[from][msg.sender] -= amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) private {
        balanceOf[from] -= amount;
        balanceOf[to] += amount;
    }
}
