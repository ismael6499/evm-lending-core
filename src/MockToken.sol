// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";


/**
 * @title MockToken
 * @dev This smart contract is a mock token used for testing
 */
contract MockToken is ERC20, Ownable {

    constructor(string memory name, string memory symbol, uint256 initialSupply) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply * 10 ** decimals());
    }

    /*
    * @dev Mints tokens to a specified address
    * @param to Address to mint tokens to
    * @param amount Amount of tokens to mint
    */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }
    
    
    /*
    * @dev Burns tokens from the caller's account
    * @param amount Amount of tokens to burn
    */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
