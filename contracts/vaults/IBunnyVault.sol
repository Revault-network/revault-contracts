// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// vault that controls a single token
interface IBunnyVault {

    function balanceOf(address account) external view returns (uint256);

    function withdrawAll() external;

    function withdraw(uint256 _amount) external;

    function withdrawUnderlying(uint256 _amount) external;

    function deposit(uint256 _amount) external;

    function depositAll() external;

    function depositBNB() external payable;

    function getReward() external;
}
