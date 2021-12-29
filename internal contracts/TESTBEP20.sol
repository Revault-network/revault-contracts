
//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/BEP20.sol";

contract TESTBEP20 is BEP20("TST", "TST") {
    constructor() public {
        _mint(msg.sender, 1e30);
    }
}
