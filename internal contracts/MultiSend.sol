//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";

contract MultiSend {

    function multisendToken(address _token, address[] calldata _recipients, uint[] calldata _amounts) external {
        for (uint i = 0; i < _recipients.length; i++) {
            address recipient = _recipients[i];
            uint amount = _amounts[i];
            IBEP20(_token).transferFrom(msg.sender, recipient, amount);
        }
    }
}
