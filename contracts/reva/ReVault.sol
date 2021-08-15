// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "./interfaces/IRevaChef.sol";
import "./interfaces/IRevaUserProxy.sol";
import "./interfaces/IRevaUserProxyFactory.sol";
import "../library/interfaces/IWBNB.sol";
import "../library/interfaces/IZap.sol";

contract ReVault is OwnableUpgradeable {
    using SafeMath for uint256;

    struct VaultInfo {
        address vaultAddress; // address of vault
        address depositTokenAddress; // address of deposit token
        address nativeTokenAddress; // address of vaults native reward token
    }

    IBEP20 private reva;
    IRevaChef public revaChef;
    IRevaUserProxyFactory public revaUserProxyFactory;
    address revaFeeReceiver;
    IZap public zap;

    VaultInfo[] public vaults;

    mapping(uint => mapping(address => uint)) public userVaultPrincipal;
    mapping(address => address) public userProxyContractAddress;
    mapping(address => bool) public haveApprovedTokenToZap;
    mapping(uint => mapping(bytes4 => bool)) public approvedHarvestPaylods;

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint constant public PROFIT_DISTRIBUTION_PRECISION = 1000000;
    uint public profitToReva = 300000;
    uint public profitToRevaStakers = 10000;

    function initialize(
        address _revaChefAddress,
        address _revaTokenAddress,
        address _revaUserProxyFactoryAddress,
        address _revaFeeReceiver,
        address _zap
    ) external initializer {
        __Ownable_init();
        revaChef = IRevaChef(_revaChefAddress);
        reva = IBEP20(_revaTokenAddress);
        revaUserProxyFactory = IRevaUserProxyFactory(_revaUserProxyFactoryAddress);
        revaFeeReceiver = _revaFeeReceiver;
        zap = IZap(_zap);
    }

    /* ========== View Functions ========== */

    function vaultLength() external view returns (uint256) {
        return vaults.length;
    }
    
    function getUserVaultPrincipal(uint _vid, address _user) external view returns (uint) {
        return userVaultPrincipal[_vid][_user];
    }

    // rebalance
    function rebalanceDepositAll(uint _fromVid, uint _toVid, bytes calldata _withdrawPayload, bytes calldata _depositAllPayload) external {
        require(_fromVid != _toVid, "identical vault indices");

        VaultInfo storage fromVault = vaults[_fromVid];
        VaultInfo storage toVault = vaults[_toVid];
        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "rebalance different tokens");

        address userProxyAddress = userProxyContractAddress[msg.sender];
        uint fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, _withdrawPayload);

        IBEP20(fromVault.depositTokenAddress).transfer(userProxyAddress, fromVaultTokenAmount);
        IRevaUserProxy(userProxyAddress).callDepositVault(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, _depositAllPayload);

        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(fromVaultTokenAmount);
    }

    // some vaults like autofarm don't have a depositAll() method, so in cases like this
    // we need to call deposit(amount), but the amount returned from withdrawAll is dynamic,
    // and so the deposit(amount) payload must be created here.
    function rebalanceDepositAllDynamicAmount(uint _fromVid, uint _toVid, bytes calldata _withdrawPayload, bytes calldata _depositLeftPayload, bytes calldata _depositRightPayload) external {
        require(_fromVid != _toVid, "identical vault indices");

        VaultInfo storage fromVault = vaults[_fromVid];
        VaultInfo storage toVault = vaults[_toVid];
        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "rebalance different tokens");

        address userProxyAddress = userProxyContractAddress[msg.sender];
        uint fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, _withdrawPayload);
        IBEP20(fromVault.depositTokenAddress).transfer(userProxyAddress, fromVaultTokenAmount);

        bytes memory payload = createAmountPayload(_depositLeftPayload, abi.encodePacked(fromVaultTokenAmount), _depositRightPayload);
        IRevaUserProxy(userProxyAddress).callDepositVault(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, payload);

        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(fromVaultTokenAmount);
    }

    // some vaults such as bunny-wbnb accept BNB deposits rather than WBNB
    // this means we have to convert the withdrawn WBNB into BNB and then send it
    function rebalanceDepositAllAsBNB(uint _fromVid, uint _toVid, bytes calldata _withdrawPayload, bytes calldata _depositAllPayload) external {
        require(_fromVid != _toVid, "identical vault indices");

        VaultInfo storage fromVault = vaults[_fromVid];
        VaultInfo storage toVault = vaults[_toVid];

        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "rebalance different tokens");
        require(fromVault.depositTokenAddress == WBNB, "not a WBNB vault");

        address userProxyAddress = userProxyContractAddress[msg.sender];

        uint fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, _withdrawPayload);
        IWBNB(WBNB).withdraw(fromVaultTokenAmount);
        uint bnbAmount = address(this).balance;
        IRevaUserProxy(userProxyAddress).callDepositVault{value : bnbAmount}(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, _depositAllPayload);

        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(bnbAmount);
    }

    function withdrawFromVault(uint _vid, bytes calldata _withdrawPayload) external returns (uint returnedTokenAmount, uint returnedRevaAmount) {
        VaultInfo storage vault = vaults[_vid];

        uint prevRevaBalance = reva.balanceOf(msg.sender);
        uint userPrincipal = userVaultPrincipal[_vid][msg.sender];
        address userProxyAddress = userProxyContractAddress[msg.sender];
        require(userProxyAddress != address(0), "user proxy doesn't exist");

        IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _withdrawPayload);

        uint vaultNativeTokenAmount = IBEP20(vault.nativeTokenAddress).balanceOf(address(this));
        if (vaultNativeTokenAmount > 0) {
            _convertToReva(vault.nativeTokenAddress, vaultNativeTokenAmount, msg.sender);
        }

        uint vaultDepositTokenAmount = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        if (vaultDepositTokenAmount > userPrincipal) {
            uint profitDistributed = _distributeProfit(vaultDepositTokenAmount.sub(userPrincipal), vault.depositTokenAddress);
            uint leftOverTokenAmount = vaultDepositTokenAmount.sub(profitDistributed);

            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                IWBNB(WBNB).withdraw(leftOverTokenAmount);
                msg.sender.transfer(address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).transfer(msg.sender, leftOverTokenAmount);
            }

            userVaultPrincipal[_vid][msg.sender] = 0;
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, userPrincipal);
        } else {
            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                IWBNB(WBNB).withdraw(vaultDepositTokenAmount);
                msg.sender.transfer(address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).transfer(msg.sender, vaultDepositTokenAmount);
            }

            userVaultPrincipal[_vid][msg.sender] = userPrincipal.sub(vaultDepositTokenAmount);
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, vaultDepositTokenAmount);
        }

        uint postRevaBalance = reva.balanceOf(msg.sender);
        return (vaultDepositTokenAmount, postRevaBalance.sub(prevRevaBalance));
    }

    function depositToVaultFor(uint _amount, uint _vid, bytes calldata _depositPayload, address _user) external payable {
        // TODO: whitelist perms..?
        _depositToVault(_amount, _vid, _depositPayload, _user, msg.sender);
    }

    function depositToVault(uint _amount, uint _vid, bytes calldata _depositPayload) external payable {
        _depositToVault(_amount, _vid, _depositPayload, msg.sender, msg.sender);
    }

    function harvestVault(uint _vid, bytes calldata _payloadHarvest) external returns (uint returnedTokenAmount, uint returnedRevaAmount) {
        address userProxyAddress = userProxyContractAddress[msg.sender];
        VaultInfo storage vault = vaults[_vid];
        require(_isApprovedHarvestMethod(_vid, _payloadHarvest), "unapproved harvest method");
        uint prevRevaBalance = reva.balanceOf(msg.sender);

        IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _payloadHarvest);

        uint nativeTokenProfit = IBEP20(vault.nativeTokenAddress).balanceOf(address(this));
        if (nativeTokenProfit > 0) {
            _convertToReva(vault.nativeTokenAddress, nativeTokenProfit, msg.sender);
        }

        uint depositTokenProfit = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        uint leftoverDepositTokenProfit = 0;
        if (depositTokenProfit > 0) {
            uint profitDistributed = _distributeProfit(depositTokenProfit, vault.depositTokenAddress);
            leftoverDepositTokenProfit = depositTokenProfit.sub(profitDistributed);

            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                IWBNB(WBNB).withdraw(leftoverDepositTokenProfit);
                msg.sender.transfer(address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).transfer(msg.sender, leftoverDepositTokenProfit);
            }
        }

        revaChef.claimFor(vault.depositTokenAddress, msg.sender);
        uint postRevaBalance = reva.balanceOf(msg.sender);
        return (leftoverDepositTokenProfit, postRevaBalance.sub(prevRevaBalance));
    }

	receive() external payable {
		require(msg.sender == WBNB, "receive only from WBNB contract");
	}

    /* ========== Private Functions ========== */

    function _depositToVault(uint _amount, uint _vid, bytes calldata _depositPayload, address _user, address _from) private {
        VaultInfo storage vault = vaults[_vid];

        address userProxyAddress = userProxyContractAddress[_user];
        if (userProxyAddress == address(0)) {
            userProxyAddress = revaUserProxyFactory.createUserProxy();
            userProxyContractAddress[_user] = userProxyAddress;
        }

        if (msg.value > 0) {
            require(msg.value == _amount, "msg.value doesn't match amount");
            IRevaUserProxy(userProxyAddress).callDepositVault{ value: msg.value }(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _depositPayload);
        } else {
            IBEP20(vault.depositTokenAddress).transferFrom(_from, userProxyAddress, _amount);
            IRevaUserProxy(userProxyAddress).callDepositVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _depositPayload);
        }

        uint vaultNativeTokenAmount = IBEP20(vault.nativeTokenAddress).balanceOf(address(this));
        if (vaultNativeTokenAmount > 0) {
            _convertToReva(vault.nativeTokenAddress, vaultNativeTokenAmount, _user);
        }

        revaChef.notifyDeposited(_user, vault.depositTokenAddress, _amount);
        userVaultPrincipal[_vid][_user] = userVaultPrincipal[_vid][_user].add(_amount);
    }


    function _withdrawFromUnderlyingVault(address _user, VaultInfo storage vault, uint _vid, bytes calldata _payload) private returns (uint) {
        address userProxyAddress = userProxyContractAddress[_user];
        uint userPrincipal = userVaultPrincipal[_vid][_user];

        IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _payload);

        uint depositTokenAmount = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        uint vaultNativeTokenAmount = IBEP20(vault.nativeTokenAddress).balanceOf(address(this));

        if (vaultNativeTokenAmount > 0) {
            _convertToReva(vault.nativeTokenAddress, vaultNativeTokenAmount, _user);
        }

        if (depositTokenAmount > userPrincipal) {
            uint depositTokenProfit = depositTokenAmount.sub(userPrincipal);
            uint profitDistributed = _distributeProfit(depositTokenProfit, vault.depositTokenAddress);
            uint leftoverDepositToken = depositTokenAmount.sub(profitDistributed);

            userVaultPrincipal[_vid][_user] = 0;
            return leftoverDepositToken;
        } else {
            userVaultPrincipal[_vid][_user] = userPrincipal.sub(depositTokenAmount);
            return depositTokenAmount;
        }
    }

    // TODO: assembly optimization
    function createAmountPayload(bytes memory _leftCallData, bytes memory _newData, bytes memory _rightCallData) private pure returns (bytes memory) {
        bytes memory payload = new bytes(_leftCallData.length + _rightCallData.length + 1);

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

    function _convertToReva(address fromToken, uint amount, address to) private {
        if (!haveApprovedTokenToZap[fromToken]) {
            IBEP20(fromToken).approve(address(zap), uint(~0));
            haveApprovedTokenToZap[fromToken] = true;
        }
        zap.zapInTokenTo(fromToken, amount, address(reva), to);
    }

    function _isApprovedHarvestMethod(uint vid, bytes memory payload) internal view returns (bool) {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        return approvedHarvestPaylods[vid][sig];
    }

    function _distributeProfit(uint profitTokens, address depositTokenAddress)
            private returns (uint profitDistributed) {
        uint profitToRevaTokens = profitTokens.mul(profitToReva).div(PROFIT_DISTRIBUTION_PRECISION);
        uint profitToRevaStakersTokens = profitTokens.mul(profitToRevaStakers).div(PROFIT_DISTRIBUTION_PRECISION);

        _convertToReva(depositTokenAddress, profitToRevaTokens, msg.sender);
        _convertToReva(depositTokenAddress, profitToRevaStakersTokens, revaFeeReceiver);

        return profitToRevaTokens.add(profitToRevaStakersTokens);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // salvage purpose only for when stupid people send tokens here
    function withdrawToken(address tokenToWithdraw, uint amount) external onlyOwner {
        IBEP20(tokenToWithdraw).transfer(msg.sender, amount);
    }

    function addVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _nativeTokenAddress
    ) external onlyOwner {
        require(_vaultAddress != address(0), 'zero address');
        vaults.push(VaultInfo(_vaultAddress, _depositTokenAddress, _nativeTokenAddress));
    }

    function setHarvestMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyOwner {
        approvedHarvestPaylods[_vid][_methodSig] = _approved;
    }

    function setProfitToReva(uint _profitToReva) external onlyOwner {
        require(_profitToReva.add(profitToRevaStakers) < PROFIT_DISTRIBUTION_PRECISION);
        profitToReva = _profitToReva;
    }

    function setProfitToRevaStakers(uint _profitToRevaStakers) external onlyOwner {
        require(_profitToRevaStakers.add(profitToReva) < PROFIT_DISTRIBUTION_PRECISION);
        profitToRevaStakers = _profitToRevaStakers;
    }
}
