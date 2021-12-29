// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IACryptoSFarm {
    function harvest(address _lpToken) external;
    function deposit(address _lpToken, uint _amount) external;
    function withdraw(address _lpToken, uint _amount) external;
    function userInfo(address _lpToken, address _user) external view returns (uint, uint, uint, uint);
    function harvestFee() external view returns (uint);
}
