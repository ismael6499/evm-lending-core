// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {IOracle} from "./interfaces/IOracle.sol";

/**
 * @title MockOracle
 * @author Agustin Acosta
 * @notice Simplified oracle implementation for simulating asset prices in test environments.
 * @dev Explicitly implements IOracle to maintain architectural parity with V2 production logic.
 */
contract MockOracle is IOracle, Ownable {
    /// @notice Internal mapping to store prices by token address (normalized to 1e18).
    mapping(address => uint256) public prices;

    /**
     * @notice Initializes the mock oracle with the caller as the owner.
     */
    constructor() Ownable(msg.sender) {}

    /**
     * @notice Manually updates the price for a specific token.
     * @dev Restricted to the contract owner.
     * @param token Address of the asset.
     * @param price Value in USD normalized to 1e18 (e.g. 1e18 = $1.00).
     */
    function setPrice(address token, uint256 price) external onlyOwner {
        prices[token] = price;
    }

    /**
     * @notice Returns the stored price for a token, or a default of 1e18 if not set.
     * @param token Address of the asset looking to be valued.
     * @return uint256 The current asset price.
     */
    function getPrice(address token) external view override returns (uint256) {
        return prices[token];
    }
}
