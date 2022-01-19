// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IACryptoSVault {
    function approve(address _to, uint256 _amount) external;
    function deposit(uint256 _amount) external;
    function depositAll() external;
    function depositETH() external payable;
    function withdraw(uint256 _shares) external;
    function withdrawAll() external;
    function withdrawETH(uint256 _shares) external;
    function withdrawAllETH() external;
    function getPricePerFullShare() external view returns (uint256);
    function balanceOf(address account) external view returns (uint256);
    function balance() external view returns (uint256);
}
