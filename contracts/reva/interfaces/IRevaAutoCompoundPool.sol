// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IRevaAutoCompoundPool {
    function notifyDeposited(uint _pid, uint _amount, address _user) external;
    function balanceOf(uint _pid, address _user) external view returns (uint);
}
