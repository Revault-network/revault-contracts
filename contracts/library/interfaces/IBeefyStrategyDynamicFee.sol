// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBeefyStrategyDynamicFee {

    function withdrawalFee() external view returns (uint256); // 10 === 0.1% fee

    function WITHDRAWAL_MAX() external view returns (uint256); // 10 === 0.1% fee

}
