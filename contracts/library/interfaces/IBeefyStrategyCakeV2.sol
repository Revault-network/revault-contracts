// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBeefyStrategyCakeV2 {

    function MAX_FEE() external view returns (uint256);

    function WITHDRAWAL_FEE_CAP() external view returns (uint256);
    function WITHDRAWAL_MAX() external view returns (uint256);

    function withdrawalFee() external view returns (uint256);
    function callFee() external view returns (uint256);
    function beefyFee() external view returns (uint256);
}
