// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IRevaStakingPool {
    function deposit(uint _pid, uint _amount) external;
    function poolInfo(uint pid) external view returns (uint, uint, uint, uint, uint, uint, uint, uint);
    function userPoolInfo(uint pid, address user) external view returns (uint, uint, uint, uint);
    function enterCompoundingPosition(uint _pid, address _user) external;
    function exitCompoundingPosition(uint _pid, uint _amount, address _user) external;
    function pendingReva(uint _pid, address _user) external view returns (uint);
    function poolLength() external view returns (uint);
}
