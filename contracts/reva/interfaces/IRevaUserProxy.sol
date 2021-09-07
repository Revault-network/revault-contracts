// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IRevaUserProxy {
    function callVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _vaultNativeTokenAddress,
        bytes calldata _payload
    ) external;
    function callDepositVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _vaultNativeTokenAddress,
        uint amount,
        bytes calldata _payload
    ) external payable;
}
