//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";

contract ERC20Mintable is ERC20 {
    constructor(string memory _name, string memory _simbol) ERC20(_name, _simbol) {}

    function mint(address to, uint256 amount) external {
        _mint(to, amount);
    }
}
