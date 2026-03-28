// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

/**
 * @title IWETH
 * @author Agustin Acosta
 * @notice Standard interface for interactions with Wrapped Ether (WETH) gateway.
 * @dev This interface is used by the LendingProtocol to abstract native ETH as an ERC20 asset.
 */
interface IWETH {
    /**
     * @notice Converts native ETH sent with the call into WETH tokens.
     * @dev Must be called with a non-zero msg.value.
     */
    function deposit() external payable;

    /**
     * @notice Unwraps a specific amount of WETH back into native ETH and sends it to the caller.
     * @param _amount The amount of WETH to unwrap.
     */
    function withdraw(uint256 _amount) external;
}
