// SPDX-License-Identifier: MIT
pragma solidity 0.8.26;

import {CollateralVault} from "./CollateralVault.sol";

/// @notice Holds the CollateralVault creation code so PawnShop's runtime stays under the EIP-170 limit.
/// Created by PawnShop in its constructor; only that shop can create vaults, each bound to the shop.
contract VaultFactory {
    error Unauthorized();

    address public immutable pawnShop;
    /// @notice Every vault this factory created (launch review ce743ba5: never a valid auction receiver).
    mapping(address => bool) public isVault;

    constructor() {
        pawnShop = msg.sender;
    }

    function create() external returns (address) {
        if (msg.sender != pawnShop) revert Unauthorized();
        address vault = address(new CollateralVault(msg.sender));
        isVault[vault] = true;
        return vault;
    }
}
