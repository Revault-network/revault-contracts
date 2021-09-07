// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IAutoFarmStratX {

    function controllerFee() external view returns (uint256);
    function controllerFeeMax() external view returns (uint256);
    function controllerFeeUL() external view returns (uint256);

    function entranceFeeFactor() external view returns (uint256);
    function entranceFeeFactorMax() external view returns (uint256);
    function entranceFeeFactorLL() external view returns (uint256);
}
