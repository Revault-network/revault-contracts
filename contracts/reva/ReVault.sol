// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;
pragma experimental ABIEncoderV2;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "./interfaces/IRevaChef.sol";
import "./interfaces/IRevaUserProxy.sol";
import "./interfaces/IRevaUserProxyFactory.sol";
import "../library/TransferHelper.sol";
import "../library/ReentrancyGuard.sol";
import "../library/interfaces/IWBNB.sol";
import "../library/interfaces/IZap.sol";

contract ReVault is OwnableUpgradeable, ReentrancyGuard, TransferHelper {
    using SafeMath for uint256;
    using SafeBEP20 for IBEP20;

    struct VaultInfo {
        address vaultAddress; // address of vault
        address depositTokenAddress; // address of deposit token
        address nativeTokenAddress; // address of vaults native reward token
    }

    struct VaultFarmInfo {
        address farmAddress; // address of vault farm
        address farmTokenAddress; // address of farm deposit token, usually vault address
    }

    IBEP20 private reva;
    IRevaChef public revaChef;
    IRevaUserProxyFactory public revaUserProxyFactory;
    IZap public zap;
    address public revaFeeReceiver;
    address public zapAndDeposit;

    uint public profitToReva;
    uint public profitToRevaStakers;

    VaultInfo[] public vaults;

    mapping(uint => mapping(address => uint)) public userVaultPrincipal;
    mapping(address => address) public userProxyContractAddress;
    mapping(address => bool) public haveApprovedTokenToZap;
    mapping(bytes32 => bool) public vaultExists;

    // approved payloads mapping
    mapping(uint => mapping(bytes4 => bool)) public approvedDepositPayloads;
    mapping(uint => mapping(bytes4 => bool)) public approvedWithdrawPayloads;
    mapping(uint => mapping(bytes4 => bool)) public approvedHarvestPayloads;

    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;

    uint public constant PROFIT_DISTRIBUTION_PRECISION = 1000000;
    uint public constant MAX_PROFIT_TO_REVA = 500000;
    uint public constant MAX_PROFIT_TO_REVA_STAKERS = 200000;

    address public admin;

    // vid => address[] of tokens received when harvesting
    mapping (uint => address[]) public harvestTokens;
    // vault id => harvest address. Some vaults have external address that must be called for
    // harvesting (e.g acryptos). Will still use approved harvest payloads.
    mapping(uint => VaultFarmInfo) public vaultFarmInfo;
    mapping(uint => mapping(bytes4 => bool)) public approvedFarmDepositPayloads;
    mapping(uint => mapping(bytes4 => bool)) public approvedFarmWithdrawPayloads;

    event SetProfitToReva(uint profitToReva);
    event SetProfitToRevaStakers(uint profitToRevaStakers);
    event SetZapAndDeposit(address zapAndDepositAddress);
    event SetAdmin(address admin);

    function initialize(
        address _revaChefAddress,
        address _revaTokenAddress,
        address _revaUserProxyFactoryAddress,
        address _revaFeeReceiver,
        address _zap,
        uint _profitToReva,
        uint _profitToRevaStakers
    ) external initializer {
        __Ownable_init();
        require(_profitToReva <= MAX_PROFIT_TO_REVA);
        require(_profitToRevaStakers <= MAX_PROFIT_TO_REVA_STAKERS);
        revaChef = IRevaChef(_revaChefAddress);
        reva = IBEP20(_revaTokenAddress);
        revaUserProxyFactory = IRevaUserProxyFactory(_revaUserProxyFactoryAddress);
        revaFeeReceiver = _revaFeeReceiver;
        zap = IZap(_zap);
        profitToReva = _profitToReva;
        profitToRevaStakers = _profitToRevaStakers;
    }

    modifier nonDuplicateVault(address _vaultAddress, address _depositTokenAddress, address _nativeTokenAddress) {
        require(!vaultExists[keccak256(abi.encodePacked(_vaultAddress, _depositTokenAddress, _nativeTokenAddress))], "DUP");
        _;
    }

    modifier onlyAdminOrOwner() {
        require(msg.sender == admin || msg.sender == owner(), "PERM");
        _;
    }

    /* ========== View Functions ========== */

    function vaultLength() external view returns (uint256) {
        return vaults.length;
    }
    
    // rebalance
    function rebalanceDepositAll(
        uint _fromVid,
        uint _toVid,
        bytes calldata _withdrawPayload,
        bytes calldata _depositAllPayload
    ) external nonReentrant {
        _requireIsApprovedWithdrawMethod(_fromVid, _withdrawPayload);
        _requireIsApprovedDepositMethod(_toVid, _depositAllPayload);
        require(_fromVid != _toVid, "VID");

        VaultInfo memory fromVault = vaults[_fromVid];
        VaultInfo memory toVault = vaults[_toVid];
        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "DTA");

        uint fromVaultUserPrincipal = userVaultPrincipal[_fromVid][msg.sender];
        address userProxyAddress = userProxyContractAddress[msg.sender];
        uint fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, _withdrawPayload);

        if (fromVault.depositTokenAddress == WBNB) {
            IRevaUserProxy(userProxyAddress).callDepositVault{ value: fromVaultTokenAmount }(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, fromVaultTokenAmount, _depositAllPayload);
        } else {
            IBEP20(fromVault.depositTokenAddress).safeTransfer(userProxyAddress, fromVaultTokenAmount);
            IRevaUserProxy(userProxyAddress).callDepositVault(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, fromVaultTokenAmount, _depositAllPayload);
        }

        _handleHarvest(_toVid, msg.sender);

        if (fromVaultTokenAmount > fromVaultUserPrincipal) {
            revaChef.notifyDeposited(msg.sender, toVault.depositTokenAddress, fromVaultTokenAmount.sub(fromVaultUserPrincipal));
        }
        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(fromVaultTokenAmount);
    }

    // some vaults like autofarm don't have a depositAll() method, so in cases like this
    // we need to call deposit(amount), but the amount returned from withdrawAll is dynamic,
    // and so the deposit(amount) payload must be created here.
    function rebalanceDepositAllDynamicAmount(
        uint _fromVid,
        uint _toVid,
        bytes calldata _withdrawPayload,
        bytes calldata _depositLeftPayload,
        bytes calldata _depositRightPayload
    ) external nonReentrant {
        _requireIsApprovedWithdrawMethod(_fromVid, _withdrawPayload);
        _requireIsApprovedDepositMethod(_toVid, _depositLeftPayload);
        require(_fromVid != _toVid, "VID");

        VaultInfo memory fromVault = vaults[_fromVid];
        VaultInfo memory toVault = vaults[_toVid];
        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "DTA");

        uint fromVaultUserPrincipal = userVaultPrincipal[_fromVid][msg.sender];
        address userProxyAddress = userProxyContractAddress[msg.sender];
        uint fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, _withdrawPayload);
        IBEP20(fromVault.depositTokenAddress).safeTransfer(userProxyAddress, fromVaultTokenAmount);

        {
            bytes memory payload = abi.encodePacked(_depositLeftPayload, fromVaultTokenAmount, _depositRightPayload);
            IRevaUserProxy(userProxyAddress).callDepositVault(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, fromVaultTokenAmount, payload);
        }

        _handleHarvest(_toVid, msg.sender);

        if (fromVaultTokenAmount > fromVaultUserPrincipal) {
            revaChef.notifyDeposited(msg.sender, toVault.depositTokenAddress, fromVaultTokenAmount.sub(fromVaultUserPrincipal));
        }
        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(fromVaultTokenAmount);
    }

    // generic rebalance function, due to replace others
    // payloads order - [withdrawVault, withdrawFarm, depositVault, depositFarm]
    function rebalanceVaultToVault(
        uint _fromVid,
        uint _toVid,
        bytes[4] calldata payloads
    ) external nonReentrant {
        _requireIsApprovedWithdrawMethod(_fromVid, payloads[0]);
        _requireIsApprovedDepositMethod(_toVid, payloads[2]);
        require(_fromVid != _toVid, "VID");

        VaultInfo memory fromVault = vaults[_fromVid];
        VaultInfo memory toVault = vaults[_toVid];
        require(toVault.depositTokenAddress == fromVault.depositTokenAddress, "DTA");

        uint fromVaultUserPrincipal = userVaultPrincipal[_fromVid][msg.sender];
        address userProxyAddress = userProxyContractAddress[msg.sender];

        uint fromVaultTokenAmount;
        if (payloads[1].length > 0) {
            _requireIsApprovedFarmWithdrawMethod(_fromVid, payloads[1]);
            fromVaultTokenAmount = _withdrawFromUnderlyingFarmAndVault(msg.sender, _fromVid, payloads[1], payloads[0]);
        } else {
            fromVaultTokenAmount = _withdrawFromUnderlyingVault(msg.sender, fromVault, _fromVid, payloads[0]);
        }

        {
            if (fromVault.depositTokenAddress == WBNB) {
                IRevaUserProxy(userProxyAddress).callDepositVault{ value: fromVaultTokenAmount }(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, fromVaultTokenAmount, payloads[2]);
            } else {
                IBEP20(fromVault.depositTokenAddress).safeTransfer(userProxyAddress, fromVaultTokenAmount);
                bytes memory payload = abi.encodePacked(payloads[2], fromVaultTokenAmount);
                IRevaUserProxy(userProxyAddress).callDepositVault(toVault.vaultAddress, toVault.depositTokenAddress, toVault.nativeTokenAddress, fromVaultTokenAmount, payload);
            }
            if (payloads[3].length > 0) {
                _requireIsApprovedFarmDepositMethod(_toVid, payloads[3]);
                VaultFarmInfo memory farmInfo = vaultFarmInfo[_toVid];
                uint farmTokenAmount = IBEP20(farmInfo.farmTokenAddress).balanceOf(userProxyAddress);
                bytes memory depositFarmPayload = abi.encodePacked(payloads[3], farmTokenAmount);
                IRevaUserProxy(userProxyAddress).callDepositVault(farmInfo.farmAddress, farmInfo.farmTokenAddress, toVault.nativeTokenAddress, farmTokenAmount, depositFarmPayload);
            }
        }

        _handleHarvest(_toVid, msg.sender);

        if (fromVaultTokenAmount > fromVaultUserPrincipal) {
            revaChef.notifyDeposited(msg.sender, toVault.depositTokenAddress, fromVaultTokenAmount.sub(fromVaultUserPrincipal));
        }
        userVaultPrincipal[_toVid][msg.sender] = userVaultPrincipal[_toVid][msg.sender].add(fromVaultTokenAmount);
    }


    function withdrawFromVaultAndClaim(uint _vid, bytes calldata _withdrawPayload) external nonReentrant {
        _withdrawFromVault(_vid, _withdrawPayload);
        revaChef.claimFor(vaults[_vid].depositTokenAddress, msg.sender);
    }

    function withdrawFromVault(uint _vid, bytes calldata _withdrawPayload) external nonReentrant returns (uint returnedTokenAmount, uint returnedRevaAmount) {
        return _withdrawFromVault(_vid, _withdrawPayload);
    }

    function depositToVaultFor(uint _amount, uint _vid, bytes calldata _depositPayload, address _user) external nonReentrant payable {
        require(tx.origin == _user, "USER");
        require(msg.sender == zapAndDeposit, "ZAD");
        _depositToVault(_amount, _vid, _depositPayload, _user, msg.sender);
    }

    function depositToVaultAndFarmFor(
        uint _amount,
        uint _vid,
        bytes calldata _depositVaultPayload,
        bytes calldata _depositFarmLeftPayload,
        address _user
    ) external nonReentrant payable {
        require(tx.origin == _user, "USER");
        require(msg.sender == zapAndDeposit, "ZAD");
        _requireIsApprovedFarmDepositMethod(_vid, _depositFarmLeftPayload);
        _depositToVault(_amount, _vid, _depositVaultPayload, _user, msg.sender);

        VaultFarmInfo memory farmInfo = vaultFarmInfo[_vid];
        VaultInfo memory vault = vaults[_vid];
        address userProxyAddress = userProxyContractAddress[_user];
        uint farmTokenAmount = IBEP20(farmInfo.farmTokenAddress).balanceOf(userProxyAddress);
        bytes memory depositFarmPayload = abi.encodePacked(_depositFarmLeftPayload, farmTokenAmount);

        IRevaUserProxy(userProxyAddress).callDepositVault(farmInfo.farmAddress, farmInfo.farmTokenAddress, vault.nativeTokenAddress, farmTokenAmount, depositFarmPayload);
    }

    function depositToVault(uint _amount, uint _vid, bytes calldata _depositPayload) external nonReentrant payable {
        _depositToVault(_amount, _vid, _depositPayload, msg.sender, msg.sender);
    }

    function depositToVaultAndFarm(
        uint _amount,
        uint _vid,
        bytes calldata _depositVaultPayload,
        bytes calldata _depositFarmLeftPayload
    ) external nonReentrant payable {
        _requireIsApprovedFarmDepositMethod(_vid, _depositFarmLeftPayload);
        _depositToVault(_amount, _vid, _depositVaultPayload, msg.sender, msg.sender);

        VaultFarmInfo memory farmInfo = vaultFarmInfo[_vid];
        VaultInfo memory vault = vaults[_vid];
        address userProxyAddress = userProxyContractAddress[msg.sender];
        uint farmTokenAmount = IBEP20(farmInfo.farmTokenAddress).balanceOf(userProxyAddress);
        bytes memory depositFarmPayload = abi.encodePacked(_depositFarmLeftPayload, farmTokenAmount);

        IRevaUserProxy(userProxyAddress).callDepositVault(farmInfo.farmAddress, farmInfo.farmTokenAddress, vault.nativeTokenAddress, farmTokenAmount, depositFarmPayload);
    }

    function withdrawFromFarmAndVaultAndClaim(
        uint _vid,
        bytes calldata _withdrawFarmPayload,
        bytes calldata _withdrawVaultPayload
    ) external nonReentrant returns (uint, uint) {
        _withdrawFromFarmAndVault(_vid, _withdrawFarmPayload, _withdrawVaultPayload);
        revaChef.claimFor(vaults[_vid].depositTokenAddress, msg.sender);
    }

    function withdrawFromFarmAndVault(
        uint _vid,
        bytes calldata _withdrawFarmPayload,
        bytes calldata _withdrawVaultPayload
    ) external nonReentrant returns (uint, uint) {
        return _withdrawFromFarmAndVault(_vid, _withdrawFarmPayload, _withdrawVaultPayload);
    }

    function harvestVault(uint _vid, bytes calldata _payloadHarvest) external nonReentrant returns (uint returnedTokenAmount, uint returnedRevaAmount) {
        _requireIsApprovedHarvestMethod(_vid, _payloadHarvest);
        address userProxyAddress = userProxyContractAddress[msg.sender];
        VaultInfo memory vault = vaults[_vid];
        VaultFarmInfo memory farmInfo = vaultFarmInfo[_vid];
        uint prevRevaBalance = reva.balanceOf(msg.sender);

        if (farmInfo.farmAddress != address(0)) {
            IRevaUserProxy(userProxyAddress).callVault(farmInfo.farmAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _payloadHarvest);
        } else {
            IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _payloadHarvest);
        }

        _handleHarvest(_vid, msg.sender);

        uint depositTokenProfit;
        if (vault.depositTokenAddress == WBNB) {
            depositTokenProfit = address(this).balance;
        } else {
            depositTokenProfit = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        }
        uint leftoverDepositTokenProfit = 0;
        if (depositTokenProfit > 0) {
            uint profitDistributed = _distributeProfit(depositTokenProfit, vault.depositTokenAddress);
            leftoverDepositTokenProfit = depositTokenProfit.sub(profitDistributed);

            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                safeTransferBNB(msg.sender, address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).safeTransfer(msg.sender, leftoverDepositTokenProfit);
            }
        }

        revaChef.claimFor(vault.depositTokenAddress, msg.sender);
        uint postRevaBalance = reva.balanceOf(msg.sender);
        return (leftoverDepositTokenProfit, postRevaBalance.sub(prevRevaBalance));
    }

	receive() external payable {}

    /* ========== Private Functions ========== */

    function _withdrawFromUnderlyingFarmAndVault(
        address _user,
        uint _vid,
        bytes calldata _withdrawFarmPayload,
        bytes calldata _withdrawVaultPayload
    ) private returns (uint) {
        VaultFarmInfo memory farmInfo = vaultFarmInfo[_vid];
        VaultInfo memory vault = vaults[_vid];

        address userProxyAddress = userProxyContractAddress[_user];
        require(userProxyAddress != address(0), "PROXY");

        IRevaUserProxy(userProxyAddress).callVault(farmInfo.farmAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _withdrawFarmPayload);
        return _withdrawFromUnderlyingVault(_user, vault, _vid, _withdrawVaultPayload);
    }

    function _withdrawFromFarmAndVault(
        uint _vid,
        bytes calldata _withdrawFarmPayload,
        bytes calldata _withdrawVaultPayload
    ) private returns (uint, uint) {
        _requireIsApprovedWithdrawMethod(_vid, _withdrawVaultPayload);
        _requireIsApprovedFarmWithdrawMethod(_vid, _withdrawFarmPayload);
        VaultInfo memory vault = vaults[_vid];
        uint userPrincipal = userVaultPrincipal[_vid][msg.sender];

        uint prevRevaBalance = reva.balanceOf(msg.sender);
        address userProxyAddress = userProxyContractAddress[msg.sender];
        require(userProxyAddress != address(0), "PROXY");

        uint vaultDepositTokenAmount = _withdrawFromUnderlyingFarmAndVault(msg.sender, _vid, _withdrawFarmPayload, _withdrawVaultPayload);

        // If withdrawing WBNB, send back BNB
        if (vault.depositTokenAddress == WBNB) {
            safeTransferBNB(msg.sender, address(this).balance);
        } else {
            IBEP20(vault.depositTokenAddress).safeTransfer(msg.sender, vaultDepositTokenAmount);
        }

        if (vaultDepositTokenAmount >= userPrincipal) {
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, userPrincipal);
        } else {
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, vaultDepositTokenAmount);
        }

        uint postRevaBalance = reva.balanceOf(msg.sender);
        return (vaultDepositTokenAmount, postRevaBalance.sub(prevRevaBalance));
    }

    function _withdrawFromVault(uint _vid, bytes calldata _withdrawPayload) private returns (uint, uint) {
        _requireIsApprovedWithdrawMethod(_vid, _withdrawPayload);
        VaultInfo memory vault = vaults[_vid];

        uint prevRevaBalance = reva.balanceOf(msg.sender);
        uint userPrincipal = userVaultPrincipal[_vid][msg.sender];
        address userProxyAddress = userProxyContractAddress[msg.sender];
        require(userProxyAddress != address(0), "PROXY");

        IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _withdrawPayload);

        _handleHarvest(_vid, msg.sender);

        uint vaultDepositTokenAmount;
        if (vault.depositTokenAddress == WBNB) {
            vaultDepositTokenAmount = address(this).balance;
        }
        else {
            vaultDepositTokenAmount = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        }
        
        if (vaultDepositTokenAmount > userPrincipal) {
            uint profitDistributed = _distributeProfit(vaultDepositTokenAmount.sub(userPrincipal), vault.depositTokenAddress);
            vaultDepositTokenAmount = vaultDepositTokenAmount.sub(profitDistributed);

            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                safeTransferBNB(msg.sender, address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).safeTransfer(msg.sender, vaultDepositTokenAmount);
            }

            userVaultPrincipal[_vid][msg.sender] = 0;
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, userPrincipal);
        } else {
            // If withdrawing WBNB, send back BNB
            if (vault.depositTokenAddress == WBNB) {
                safeTransferBNB(msg.sender, address(this).balance);
            } else {
                IBEP20(vault.depositTokenAddress).safeTransfer(msg.sender, vaultDepositTokenAmount);
            }

            userVaultPrincipal[_vid][msg.sender] = userPrincipal.sub(vaultDepositTokenAmount);
            revaChef.notifyWithdrawn(msg.sender, vault.depositTokenAddress, vaultDepositTokenAmount);
        }

        uint postRevaBalance = reva.balanceOf(msg.sender);
        return (vaultDepositTokenAmount, postRevaBalance.sub(prevRevaBalance));
    }

    function _depositToVault(uint _amount, uint _vid, bytes calldata _depositPayload, address _user, address _from) private {
        _requireIsApprovedDepositMethod(_vid, _depositPayload);
        VaultInfo memory vault = vaults[_vid];

        address userProxyAddress = userProxyContractAddress[_user];
        if (userProxyAddress == address(0)) {
            userProxyAddress = revaUserProxyFactory.createUserProxy();
            userProxyContractAddress[_user] = userProxyAddress;
        }

        if (msg.value > 0) {
            require(msg.value == _amount, "VAL");
            IRevaUserProxy(userProxyAddress).callDepositVault{ value: msg.value }(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, msg.value, _depositPayload);
        } else {
            IBEP20(vault.depositTokenAddress).safeTransferFrom(_from, userProxyAddress, _amount);
            IRevaUserProxy(userProxyAddress).callDepositVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _amount, _depositPayload);
        }

        _handleHarvest(_vid, _user);

        revaChef.notifyDeposited(_user, vault.depositTokenAddress, _amount);
        userVaultPrincipal[_vid][_user] = userVaultPrincipal[_vid][_user].add(_amount);
    }


    function _withdrawFromUnderlyingVault(
        address _user,
        VaultInfo memory vault,
        uint _vid,
        bytes memory _payload
    ) private returns (uint) {
        address userProxyAddress = userProxyContractAddress[_user];
        uint userPrincipal = userVaultPrincipal[_vid][_user];

        IRevaUserProxy(userProxyAddress).callVault(vault.vaultAddress, vault.depositTokenAddress, vault.nativeTokenAddress, _payload);

        uint depositTokenAmount;
        if (vault.depositTokenAddress == WBNB) {
            depositTokenAmount = address(this).balance;
        } else {
            depositTokenAmount = IBEP20(vault.depositTokenAddress).balanceOf(address(this));
        }

        _handleHarvest(_vid, _user);

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

    function _handleHarvest(uint _vid, address _user) private {
        uint vaultNativeTokenAmount = IBEP20(vaults[_vid].nativeTokenAddress).balanceOf(address(this));
        if (vaultNativeTokenAmount > 0) {
            _convertToReva(vaults[_vid].nativeTokenAddress, vaultNativeTokenAmount, _user);
        }
        address[] memory harvestedTokens = harvestTokens[_vid];
        for (uint i = 0; i < harvestedTokens.length; i++) {
            address tokenAddress = harvestedTokens[i];
            IRevaUserProxy(userProxyContractAddress[_user]).callVault(address(0), vaults[_vid].depositTokenAddress, tokenAddress, "");
            uint tokenAmount = IBEP20(tokenAddress).balanceOf(address(this));
            if (tokenAmount > 0) {
                _convertToReva(tokenAddress, tokenAmount, _user);
            }
        }
    }

    function _convertToReva(address fromToken, uint amount, address to) private {
        if (fromToken == WBNB) {
            zap.zapInTo{ value: amount }(address(reva), to);
            return;
        }
        if (!haveApprovedTokenToZap[fromToken]) {
            IBEP20(fromToken).approve(address(zap), uint(~0));
            haveApprovedTokenToZap[fromToken] = true;
        }
        zap.zapInTokenTo(fromToken, amount, address(reva), to);
    }

    function _requireIsApprovedFarmDepositMethod(uint vid, bytes memory payload) internal view {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        require(approvedFarmDepositPayloads[vid][sig], "FDM");
    }

    function _requireIsApprovedFarmWithdrawMethod(uint vid, bytes memory payload) internal view {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        require(approvedFarmWithdrawPayloads[vid][sig], "FWM");
    }

    function _requireIsApprovedDepositMethod(uint vid, bytes memory payload) internal view {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        require(approvedDepositPayloads[vid][sig], "DM");
    }

    function _requireIsApprovedWithdrawMethod(uint vid, bytes memory payload) internal view {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        require(approvedWithdrawPayloads[vid][sig], "WM");
    }

    function _requireIsApprovedHarvestMethod(uint vid, bytes memory payload) internal view {
        bytes4 sig;
        assembly {
            sig := mload(add(payload, 32))
        }
        require(approvedHarvestPayloads[vid][sig], "HM");
    }

    function _distributeProfit(uint profitTokens, address depositTokenAddress)
            private returns (uint profitDistributed) {
        uint profitToRevaTokens = profitTokens.mul(profitToReva).div(PROFIT_DISTRIBUTION_PRECISION);
        uint profitToRevaStakersTokens = profitTokens.mul(profitToRevaStakers).div(PROFIT_DISTRIBUTION_PRECISION);
        
        if (profitToRevaTokens > 0) {
            _convertToReva(depositTokenAddress, profitToRevaTokens, msg.sender);
        }
        if (profitToRevaStakersTokens > 0) {
            _convertToReva(depositTokenAddress, profitToRevaStakersTokens, revaFeeReceiver);
        }

        return profitToRevaTokens.add(profitToRevaStakersTokens);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    // salvage purpose only for when stupid people send tokens here
    function withdrawToken(address tokenToWithdraw, uint amount) external onlyOwner {
        IBEP20(tokenToWithdraw).safeTransfer(msg.sender, amount);
    }

    function addVault(
        address _vaultAddress,
        address _depositTokenAddress,
        address _nativeTokenAddress
    ) external nonDuplicateVault(_vaultAddress, _depositTokenAddress, _nativeTokenAddress) onlyAdminOrOwner {
        require(_vaultAddress != address(0));
        vaults.push(VaultInfo(_vaultAddress, _depositTokenAddress, _nativeTokenAddress));
        vaultExists[keccak256(abi.encodePacked(_vaultAddress, _depositTokenAddress, _nativeTokenAddress))] = true;
    }

    function setAdmin(address _admin) external onlyAdminOrOwner {
        admin = _admin;
        emit SetAdmin(admin);
    }

    function setHarvestTokens(uint _vid, address[] memory _tokens) external onlyAdminOrOwner {
        harvestTokens[_vid] = _tokens;
    }

    function setDepositMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyAdminOrOwner {
        approvedDepositPayloads[_vid][_methodSig] = _approved;
    }

    function setWithdrawMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyAdminOrOwner {
        approvedWithdrawPayloads[_vid][_methodSig] = _approved;
    }

    function setHarvestMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyAdminOrOwner {
        approvedHarvestPayloads[_vid][_methodSig] = _approved;
    }

    function setVaultFarmAddresses(uint _vid, address vaultFarmAddress, address farmTokenAddress) external onlyAdminOrOwner {
        vaultFarmInfo[_vid] = VaultFarmInfo(vaultFarmAddress, farmTokenAddress);
    }

    function setFarmDepositMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyAdminOrOwner {
        approvedFarmDepositPayloads[_vid][_methodSig] = _approved;
    }

    function setFarmWithdrawMethod(uint _vid, bytes4 _methodSig, bool _approved) external onlyAdminOrOwner {
        approvedFarmWithdrawPayloads[_vid][_methodSig] = _approved;
    }

    function setProfitToReva(uint _profitToReva) external onlyOwner {
        require(_profitToReva <= MAX_PROFIT_TO_REVA);
        profitToReva = _profitToReva;
        emit SetProfitToReva(_profitToReva);
    }

    function setProfitToRevaStakers(uint _profitToRevaStakers) external onlyOwner {
        require(_profitToRevaStakers <= MAX_PROFIT_TO_REVA_STAKERS);
        profitToRevaStakers = _profitToRevaStakers;
        emit SetProfitToRevaStakers(_profitToRevaStakers);
    }

    function setZapAndDeposit(address _zapAndDeposit) external onlyOwner {
        zapAndDeposit = _zapAndDeposit;
        emit SetZapAndDeposit(_zapAndDeposit);
    }
}
