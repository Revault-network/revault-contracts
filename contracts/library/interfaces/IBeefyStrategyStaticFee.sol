// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBeefyStrategyStaticFee {

    function WITHDRAWAL_FEE() external view returns (uint256); // 10 === 0.1% fee

}
