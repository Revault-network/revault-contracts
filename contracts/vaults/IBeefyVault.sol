// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// vault that controls a single token
interface IBeefyVault {

    function strategy() external view returns (address);

    function withdrawAll() external;

    function depositAll() external;

    function withdraw(uint256 _amount) external;

    function deposit(uint256 _amount) external;

    function balanceOf(address account) external view returns (uint256);

    function balance() external view returns (uint256);

    function totalSupply() external view returns (uint256);
}
