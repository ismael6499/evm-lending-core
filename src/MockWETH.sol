// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockToken} from "./MockToken.sol";

/**
 * @title MockWETH
 * @author Agustin Acosta
 * @notice Simulation of the WETH9 contract for protocol development.
 */
contract MockWETH is MockToken {
    constructor() MockToken("Wrapped Ether", "WETH", 18, 0) {}

    /**
     * @notice Simulates wrapping native ETH into WETH tokens.
     */
    function deposit() external payable {
        _mint(msg.sender, msg.value);
    }

    /**
     * @notice Simulates unwrapping WETH tokens back into native ETH.
     */
    function withdraw(uint256 _amount) external {
        _burn(msg.sender, _amount);
        (bool success, ) = msg.sender.call{value: _amount}("");
        if (!success) revert("ETH transfer failed");
    }

    /// @dev To receive ETH from withdraw()
    receive() external payable {}
}
