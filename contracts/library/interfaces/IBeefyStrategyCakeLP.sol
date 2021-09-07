// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IBeefyStrategyCakeLP {

    function STRATEGIST_FEE() external view returns (uint256);
    function MAX_FEE() external view returns (uint256);
    function MAX_CALL_FEE() external view returns (uint256);

    function WITHDRAWAL_FEE() external view returns (uint256);
    function WITHDRAWAL_MAX() external view returns (uint256);

    function callFee() external view returns (uint256);
    function beefyFee() external view returns (uint256);
}
