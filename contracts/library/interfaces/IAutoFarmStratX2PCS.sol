// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IAutoFarmStratX2PCS {

    function controllerFee() external view returns (uint256);
    function controllerFeeMax() external view returns (uint256);
    function controllerFeeUL() external view returns (uint256);

    function entranceFeeFactor() external view returns (uint256);
    function entranceFeeFactorMax() external view returns (uint256);
    function entranceFeeFactorLL() external view returns (uint256);

    function withdrawFeeFactor() external view returns (uint256);
    function withdrawFeeFactorMax() external view returns (uint256);
    function withdrawFeeFactorLL() external view returns (uint256);

    function wantLockedTotal() external view returns (uint256);
    function sharesTotal() external view returns (uint256);
}
