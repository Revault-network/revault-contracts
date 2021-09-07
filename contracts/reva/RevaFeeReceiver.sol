// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";

/**
 * @dev This contract receives reva fees from every transfer, and performance fees
 * from the revault contract.
 */
contract RevaFeeReceiver is OwnableUpgradeable {
    using SafeBEP20 for IBEP20;

    address public revaToken;

    function initialize(address _revaToken) external initializer {
        __Ownable_init();
        revaToken = _revaToken;
    }

    function addRecipient(address _recipient) external onlyOwner {
        IBEP20(revaToken).safeApprove(_recipient, uint(~0));
    }

}