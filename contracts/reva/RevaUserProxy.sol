// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "./interfaces/IRevaUserProxy.sol";
import "../vaults/IBunnyVault.sol";
import "../vaults/IAutoFarm.sol";
import "../vaults/IBeefyVault.sol";
import "../library/interfaces/IWBNB.sol";

// This contract performs withdraws/deposits on behalf
// of users who deposit into a ReVault contract. This is so
// that if a user wants to withdraw after 3 days of inactivity
// they may do so without paying a fee. Otherwise, every time
// the central ReVault contract would deposit into a vault,
// the 3 days would be reset.
contract RevaUserProxy is IRevaUserProxy, Ownable {

    mapping(address => mapping(address => bool)) public haveApprovedTokenToVault;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    function callVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _vaultNativeTokenAddress,
        bytes calldata _payload
    ) external override onlyOwner {
        (bool success,) = _vaultAddress.call{value : 0}(_payload);
        require(success, "vault call");

        if (address(this).balance > 0 && _depositTokenAddress == WBNB) {
            IWBNB(WBNB).deposit{ value: address(this).balance }();
        }
        uint depositTokenAmount = IBEP20(_depositTokenAddress).balanceOf(address(this));
        uint vaultTokenAmount = IBEP20(_vaultNativeTokenAddress).balanceOf(address(this));
        if (depositTokenAmount > 0) {
            IBEP20(_depositTokenAddress).transfer(msg.sender, depositTokenAmount);
        }
        if (vaultTokenAmount > 0) {
            IBEP20(_vaultNativeTokenAddress).transfer(msg.sender, vaultTokenAmount);
        }
    }

    function callDepositVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _vaultNativeTokenAddress,
        bytes calldata _payload
    ) public override payable onlyOwner {
        if (!haveApprovedTokenToVault[_depositTokenAddress][_vaultAddress]) {
            IBEP20(_depositTokenAddress).approve(_vaultAddress, uint(~0));
            haveApprovedTokenToVault[_depositTokenAddress][_vaultAddress] = true;
        }

        (bool success,) = _vaultAddress.call{value : msg.value}(_payload);
        require(success, "vault call");

        require(IBEP20(_depositTokenAddress).balanceOf(address(this)) == 0, "Proxy didn't deposit all");

        uint vaultTokenAmount = IBEP20(_vaultNativeTokenAddress).balanceOf(address(this));
        if (vaultTokenAmount > 0) {
            IBEP20(_vaultNativeTokenAddress).transfer(msg.sender, vaultTokenAmount);
        }
    }

    receive() external payable {}
}
