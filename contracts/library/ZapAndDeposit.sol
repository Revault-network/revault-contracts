// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./interfaces/IZap.sol";
import "../reva/interfaces/IReVault.sol";
import "../library/interfaces/IWBNB.sol";

contract ZapAndDeposit is OwnableUpgradeable {

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

    /* ========== View Functions ========== */

    /* ========== External Functions ========== */

    function zapInTokenAndDeposit(
        address _from,
        uint amount,
        address _to,
        uint _vid,
        bytes memory _leftCallData,
        bytes memory _rightCallData
    ) public {
        IBEP20(_from).transferFrom(msg.sender, address(this), amount);
        approveToZap(_from);
        zap.zapInTokenTo(_from, amount, _to, address(this));
        approveToRevault(_to);
        uint balance = IBEP20(_to).balanceOf(address(this));
        bytes memory newData = abi.encodePacked(balance);
        bytes memory payload = createAmountPayload(_leftCallData, newData, _rightCallData);
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
        bytes memory newData = abi.encodePacked(balance);
        bytes memory payload = createAmountPayload(_leftCallData, newData, _rightCallData);
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
        IWBNB(WBNB).transferFrom(msg.sender, address(this), amount);
        IWBNB(WBNB).withdraw(amount);
        revault.depositToVaultFor{ value: amount }(amount, _vid, payload, msg.sender);
    }

    /* ========== Private Functions ========== */

    // TODO: assembly optimization
    function createAmountPayload(bytes memory _leftCallData, bytes memory _newData, bytes memory _rightCallData) private pure returns (bytes memory) {
        bytes memory payload = new bytes(_leftCallData.length + _rightCallData.length + _newData.length);

        uint k = 0;
        for (uint i = 0; i < _leftCallData.length; i++) {
            payload[k] = _leftCallData[i];
            k++;
        }
        for (uint i = 0; i < _newData.length; i++) {
            payload[k] = _newData[i];
            k++;
        }
        for (uint i = 0; i < _rightCallData.length; i++) {
            payload[k] = _rightCallData[i];
            k++;
        }
        return payload;
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function approveToZap(address token) private {
        if (!haveApprovedTokenToZap[token]) {
            IBEP20(token).approve(address(zap), uint(~0));
            haveApprovedTokenToZap[token] = true;
        }
    }

    function approveToRevault(address token) private {
        if (!haveApprovedTokenToRevault[token]) {
            IBEP20(token).approve(address(revault), uint(~0));
            haveApprovedTokenToRevault[token] = true;
        }
    }

}

