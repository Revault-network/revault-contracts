// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IReVault {
    function depositToVaultFor(uint _amount, uint _vid, bytes calldata _depositPayload, address _user) external payable;
    function depositToVaultAndFarmFor(
        uint _amount,
        uint _vid,
        bytes calldata _depositVaultPayload,
        bytes calldata _depositFarmPayload,
        address _user
    ) external payable;
}
