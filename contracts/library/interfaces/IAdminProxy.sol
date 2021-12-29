// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

interface IAdminProxy {
    function upgrade(address proxy, address implementation) external;
    function owner() external view returns (address);
}
