// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBeefyStrategyVenusBNBV2 {

    function REWARDS_FEE() external view returns (uint256);
    function CALL_FEE() external view returns (uint256);
    function TREASURY_FEE() external view returns (uint256);
    function MAX_FEE() external view returns (uint256);

    function WITHDRAWAL_FEE() external view returns (uint256);
    function WITHDRAWAL_MAX() external view returns (uint256);

}
