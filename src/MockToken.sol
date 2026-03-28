// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import "../lib/openzeppelin-contracts/contracts/token/ERC20/ERC20.sol";
import "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";

/**
 * @title MockToken
 * @author Agustin Acosta
 * @notice Simplified ERC20 token designed for protocol testing and simulation.
 * @dev Inherits OpenZeppelin's ERC20 and Ownable frameworks.
 */
contract MockToken is ERC20, Ownable {

    /**
     * @notice Initializes the mock token with a specific supply and decimal configuration.
     * @param name Full name of the token.
     * @param symbol Ticker symbol.
     * @param decimals Digit precision (e.g. 18).
     * @param initialSupply Initial multiplier for minting (final supply = initialSupply * 10^decimals).
     */
    constructor(string memory name, string memory symbol, uint8 decimals, uint256 initialSupply) ERC20(name, symbol) Ownable(msg.sender) {
        _mint(msg.sender, initialSupply * (10 ** decimals));
    }

    /**
     * @notice Mints new tokens to a target address.
     * @dev Restricted to the contract owner.
     * @param to Destination address for minted tokens.
     * @param amount Discrete quantity of tokens (including decimals) to mint.
     */
    function mint(address to, uint256 amount) external onlyOwner {
        _mint(to, amount);
    }

    /**
     * @notice Destroys tokens from the caller's balance.
     * @param amount Discrete quantity of tokens to burn.
     */
    function burn(uint256 amount) external {
        _burn(msg.sender, amount);
    }
}
