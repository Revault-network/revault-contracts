// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IRevaUserProxyFactory {
    function createUserProxy() external returns (address);
}
