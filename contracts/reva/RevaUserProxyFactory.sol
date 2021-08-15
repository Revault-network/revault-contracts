// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "./RevaUserProxy.sol";

contract RevaUserProxyFactory {

    constructor() public {
    }

    function createUserProxy() external returns (address) {
        RevaUserProxy revaUserProxyAddress = new RevaUserProxy();
        revaUserProxyAddress.transferOwnership(msg.sender);
        return address(revaUserProxyAddress);
    }
}
