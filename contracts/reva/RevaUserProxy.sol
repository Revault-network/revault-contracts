// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "./interfaces/IRevaUserProxy.sol";
import "../library/TransferHelper.sol";
import "../library/interfaces/IWBNB.sol";

// This contract performs withdraws/deposits on behalf
// of users who deposit into a ReVault contract. This is so
// that if a user wants to withdraw after 3 days of inactivity
// they may do so without paying a fee. Otherwise, every time
// the central ReVault contract would deposit into a vault,
// the 3 days would be reset.
contract RevaUserProxy is IRevaUserProxy, Ownable, TransferHelper {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

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

        uint depositTokenAmount = IBEP20(_depositTokenAddress).balanceOf(address(this));
        uint vaultTokenAmount = IBEP20(_vaultNativeTokenAddress).balanceOf(address(this));
        if (_depositTokenAddress == WBNB) {
            if (depositTokenAmount > 0) {
                IWBNB(WBNB).withdraw(depositTokenAmount);
            }
            if (address(this).balance > 0) {
                // transfer BNB like this to not run out of gas with zeppelin upgradeable contract
                safeTransferBNB(msg.sender, address(this).balance);
            }
        } else {
            if (depositTokenAmount > 0) {
                IBEP20(_depositTokenAddress).safeTransfer(msg.sender, depositTokenAmount);
            }
        }
        if (vaultTokenAmount > 0) {
            IBEP20(_vaultNativeTokenAddress).safeTransfer(msg.sender, vaultTokenAmount);
        }
    }

    function callDepositVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _vaultNativeTokenAddress,
        uint amount,
        bytes calldata _payload
    ) public override payable onlyOwner {
        if (!haveApprovedTokenToVault[_depositTokenAddress][_vaultAddress]) {
            IBEP20(_depositTokenAddress).approve(_vaultAddress, uint(~0));
            haveApprovedTokenToVault[_depositTokenAddress][_vaultAddress] = true;
        }

        uint prevBalance;
        if (msg.value > 0) prevBalance = address(this).balance;
        else prevBalance = IBEP20(_depositTokenAddress).balanceOf(address(this));

        (bool success,) = _vaultAddress.call{value : msg.value}(_payload);
        require(success, "vault call");

        uint postBalance;
        if (msg.value > 0) postBalance = address(this).balance;
        else postBalance = IBEP20(_depositTokenAddress).balanceOf(address(this));

        require(prevBalance.sub(postBalance) == amount, "Proxy didn't deposit exact amount");

        uint vaultTokenAmount = IBEP20(_vaultNativeTokenAddress).balanceOf(address(this));
        if (vaultTokenAmount > 0) {
            IBEP20(_vaultNativeTokenAddress).safeTransfer(msg.sender, vaultTokenAmount);
        }
    }

    receive() external payable {}
}
