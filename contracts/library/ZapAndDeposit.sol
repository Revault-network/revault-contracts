// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IZap.sol";
import "../reva/interfaces/IReVault.sol";
import "../library/interfaces/IWBNB.sol";

contract ZapAndDeposit is OwnableUpgradeable {
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANT VARIABLES ========== */

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    /* ========== STATE VARIABLES ========== */

    mapping (address => bool) public haveApprovedTokenToZap;
    mapping (address => bool) public haveApprovedTokenToRevault;

    IZap public zap;
    IReVault public revault;

    /* ========== INITIALIZER ========== */

    function initialize(address _zap, address _revault) external initializer {
        __Ownable_init();
        zap = IZap(_zap);
        revault = IReVault(_revault);
    }

    receive() external payable {}

    /* ========== External Functions ========== */

    function zapInTokenAndDeposit(
        address _from,
        uint amount,
        address _to,
        uint _vid,
        bytes memory _leftCallData,
        bytes memory _rightCallData
    ) public {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        approveToZap(_from);
        zap.zapInTokenTo(_from, amount, _to, address(this));
        approveToRevault(_to);
        uint balance = IBEP20(_to).balanceOf(address(this));
        bytes memory payload = abi.encodePacked(_leftCallData, balance, _rightCallData);
        revault.depositToVaultFor(balance, _vid, payload, msg.sender);
    }

    function zapBNBAndDeposit(
        address _to,
        uint _vid,
        bytes memory _leftCallData,
        bytes memory _rightCallData
    ) external payable {
        zap.zapIn{ value : msg.value }(_to);
        approveToRevault(_to);
        uint balance = IBEP20(_to).balanceOf(address(this));
        bytes memory payload = abi.encodePacked(_leftCallData, balance, _rightCallData);
        revault.depositToVaultFor(balance, _vid, payload, msg.sender);
    }

    function zapBNBToWBNBAndDeposit(
        uint _vid,
        bytes memory payload
    ) external payable {
        approveToRevault(WBNB);
        IWBNB(WBNB).deposit{ value: msg.value }();
        revault.depositToVaultFor(msg.value, _vid, payload, msg.sender);
    }

    function zapWBNBToBNBAndDeposit(
        uint amount,
        uint _vid,
        bytes memory payload
    ) external {
        IBEP20(WBNB).safeTransferFrom(msg.sender, address(this), amount);
        IWBNB(WBNB).withdraw(amount);
        revault.depositToVaultFor{ value: amount }(amount, _vid, payload, msg.sender);
    }

    function zapTokenToBNBAndDeposit(
        address _from,
        uint amount,
        uint _vid,
        bytes memory payload
    ) external {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        approveToZap(_from);
        zap.zapInTokenTo(_from, amount, WBNB, address(this));
        IWBNB(WBNB).withdraw(IBEP20(WBNB).balanceOf(address(this)));
        uint bnbAmount = address(this).balance;
        revault.depositToVaultFor{ value: bnbAmount }(bnbAmount, _vid, payload, msg.sender);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function approveToZap(address token) private {
        if (!haveApprovedTokenToZap[token]) {
            IBEP20(token).safeApprove(address(zap), uint(~0));
            haveApprovedTokenToZap[token] = true;
        }
    }

    function approveToRevault(address token) private {
        if (!haveApprovedTokenToRevault[token]) {
            IBEP20(token).safeApprove(address(revault), uint(~0));
            haveApprovedTokenToRevault[token] = true;
        }
    }

}

