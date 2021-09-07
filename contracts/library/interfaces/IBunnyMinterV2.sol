// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBunnyMinterV2 {

    function WITHDRAWAL_FEE_FREE_PERIOD() external view returns (uint);
    function WITHDRAWAL_FEE() external view returns (uint);
    function PERFORMANCE_FEE() external view returns (uint);
    function FEE_MAX() external view returns (uint);

    function withdrawalFee(uint amount, uint depositedAt) external view returns (uint);
    function performanceFee(uint profit) external view returns (uint);

}

