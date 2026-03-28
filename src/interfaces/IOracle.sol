// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IOracle
 * @author Agustin Acosta
 * @notice Interface for the price oracle to normalize asset valuations across different volatility profiles.
 * @dev Prices should be normalized to 1e18 (USD-based) for consistency in collateralization math.
 */
interface IOracle {
    /**
     * @notice Fetches the current price of a given asset.
     * @param token The address of the asset for which the price is requested.
     * @return uint256 The asset price normalized to 1e18.
     */
    function getPrice(address token) external view returns (uint256);
}
