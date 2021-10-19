// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

contract TransferHelper {
    function safeTransferBNB(address to, uint256 value) internal {
        (bool success, ) = to.call{value: value}(new bytes(0));
        require(success, 'TransferHelper::safeTransferBNB: BNB transfer failed');
    }
}
