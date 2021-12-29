// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// vault that controls a single token
interface IBunnyVaultFlipToFlip {

    // Read

    function balanceOf(address _account) external view returns (uint256);

    function depositedAt(address _account) external view returns (uint256);

    function minter() external view returns (address);

    function principalOf(address _account) external view returns (uint256);

    function sharesOf(address _account) external view returns (uint256);

    function earned(address _account) external view returns (uint256);

    function withdrawableBalanceOf(address _account) external view returns (uint256);

    function balance() external view returns (uint256);

    function totalShares() external view returns (uint256);

    function totalSupply() external view returns (uint256);

    // Write

    function deposit(uint256 _amount) external;

    function depositAll() external;

    function getReward() external;

    function withdrawUnderlying(uint256 _amountTokens) external;

    function withdrawAll() external;

}
