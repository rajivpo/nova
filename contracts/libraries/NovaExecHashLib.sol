// SPDX-License-Identifier: AGPL-3.0-only
pragma solidity 0.7.6;

/// @notice Utility library to compute a Nova execHash from a nonce, strategy address, calldata and gas price.
/// @dev Just because an execHash can be properly computed, doesn't mean it's a valid request in the registry.
library NovaExecHashLib {
    /// @dev Computes a Nova execHash from a nonce, strategy address, calldata and gas price.
    /// @return A Nova execHash: keccak256(nonce, strategy, l1Calldata, gasPrice)
    function compute(
        uint256 nonce,
        address strategy,
        bytes memory l1Calldata,
        uint256 gasPrice
    ) internal pure returns (bytes32) {
        return keccak256(abi.encodePacked(nonce, strategy, l1Calldata, gasPrice));
    }
}
