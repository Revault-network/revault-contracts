// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2; // TODO: is this alright?

interface IAutoFarm {

    struct UserInfo {
        uint256 shares;        // How many LP tokens the user has provided
        uint256 rewardDebt;    // How much pending AUTO the user is entitled to
    }

    struct PoolInfo {
        address want;               // Address of want token
        uint256 allocPoint;         // How many allocation points assigned to this pool. AUTO to distribute per block.
        uint256 lastRewardBlock;    // Last block number that AUTO distribution occurs
        uint256 accAUTOPerShare;    // Accumulated AUTO per share, times 1e12
        address strat;              // Strategy address that will auto compound want tokens
    }

    function userInfo(uint _pid, address _userAddress) external view returns (UserInfo memory);

    function poolInfo(uint _pid) external view returns (PoolInfo memory);

    function poolLength() external view returns (uint256);

    function deposit(uint256 _pid, uint256 _wantAmt) external;

    function withdrawAll(uint256 _pid) external;

    function withdraw(uint256 _pid, uint256 _amount) external;
}
