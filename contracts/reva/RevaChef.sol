// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "./RevaToken.sol";
import "./vRevaToken.sol";
import "./interfaces/IRevaChef.sol";
import "../library/interfaces/IZap.sol";

contract RevaChef is OwnableUpgradeable, IRevaChef {
    using SafeMath for uint256;

    struct RevaultUserInfo {
        uint256 balance; // in reVault token
        uint256 pending;
        uint256 rewardPaid;
    }

    struct TokenInfo {
        uint256 totalPrincipal;
        uint256 tvlBusd;
        uint256 lastRewardBlock;  // Last block number that REVAs distribution occurs.
        uint256 accRevaPerToken; // Accumulated REVAs per share, times 1e12. See below.
    }

    // The REVA TOKEN!
    RevaToken public reva;
    // zap
    IZap public zap;
    //
    address public revaultAddress;
    // REVA tokens created per block.
    uint256 public revaPerBlock; 
    // treasury
    address public treasury;
    // REVA tokens created per block for treasury.
    uint256 public revaTreasuryPerBlock; 
    // checkpoint
    uint256 public lastTreasuryRewardBlock;

    // Info of each user that deposits to a ReVault
    mapping (address => mapping (address => RevaultUserInfo)) public revaultUsers;
    // array of revault addresses
    address[] private _reVaultList;
    // mapping reVault address => reVault index
    mapping (address => TokenInfo) public tokens;
    // Total reva allocation points.
    uint256 public totalRevaAllocPoint = 0;
    //
    uint256 public accReceivedRevaFromFees;
    //
    uint256 public accWithdrawnRevaFromfees;
    // The TVL of all ReVaults combined
    uint256 public totalRevaultTvlBusd = 0;

    event NotifyDeposited(address indexed user, address indexed token, uint amount);
    event NotifyWithdrawn(address indexed user, address indexed token, uint amount);
    event RevaRewardPaid(address indexed user, address indexed token, uint amount);

    function initialize(
        address _reva,
        address _zap,
        uint256 _revaPerBlock,
        uint256 _revaTreasuryPerBlock,
        address _treasury,
        uint256 _startBlock
    ) external initializer {
        __Ownable_init();
        reva = RevaToken(_reva);
        zap = IZap(_zap);
        revaPerBlock = _revaPerBlock;
        revaTreasuryPerBlock = _revaTreasuryPerBlock;
        treasury = _treasury;
        lastTreasuryRewardBlock = _startBlock;
    }

    /* ========== MODIFIERS ========== */


    modifier onlyRevault {
        require(msg.sender == revaultAddress, "revault only");
        _;
    }

    modifier onlyTreasury {
        require(msg.sender == treasury, "treasury only");
        _;
    }

    /* ========== View Functions ========== */

    // View function to see pending REVAs from Revaults on frontend.
    function pendingReva(address _tokenAddress, address _user) external view returns (uint256) {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];

        uint256 accRevaPerToken = tokenInfo.accRevaPerToken;
        if (block.number > tokenInfo.lastRewardBlock && tokenInfo.totalPrincipal != 0) {
            uint256 multiplier = (block.number).sub(tokenInfo.lastRewardBlock);
            uint256 prevTokenTvlBusd = tokenInfo.tvlBusd;
            uint256 currTokenTvlBusd = zap.getBUSDValue(_tokenAddress, tokenInfo.totalPrincipal);
            uint256 revaReward;
            if (prevTokenTvlBusd > currTokenTvlBusd) {
                uint256 tvlDiff = prevTokenTvlBusd.sub(currTokenTvlBusd);
                revaReward = multiplier.mul(revaPerBlock).mul(currTokenTvlBusd).div(totalRevaultTvlBusd.sub(tvlDiff));
            } else if (prevTokenTvlBusd < currTokenTvlBusd) {
                uint256 tvlDiff = currTokenTvlBusd.sub(prevTokenTvlBusd);
                revaReward = multiplier.mul(revaPerBlock).mul(currTokenTvlBusd).div(totalRevaultTvlBusd.add(tvlDiff));
            }
            accRevaPerToken = accRevaPerToken.add(revaReward.mul(1e12).div(tokenInfo.totalPrincipal));

        }

        return _calcPending(accRevaPerToken, _tokenAddress, _user);
    }

    function updateRevaultRewards(address _tokenAddress, uint256 _amount, bool _isDeposit) internal {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        if (block.number <= tokenInfo.lastRewardBlock) {
            return;
        }
        // NOTE: this is done so that a new token won't get too many rewards
        if (tokenInfo.lastRewardBlock == 0) {
            tokenInfo.lastRewardBlock = block.number;
        }

        uint256 prevTokenTvlBusd = tokenInfo.tvlBusd;
        uint256 currTokenTvlBusd = zap.getBUSDValue(_tokenAddress, tokenInfo.totalPrincipal);
        if (prevTokenTvlBusd > currTokenTvlBusd) {
            uint256 tvlDiff = prevTokenTvlBusd.sub(currTokenTvlBusd);
            totalRevaultTvlBusd = totalRevaultTvlBusd.sub(tvlDiff);
        } else if (prevTokenTvlBusd < currTokenTvlBusd) {
            uint256 tvlDiff = currTokenTvlBusd.sub(prevTokenTvlBusd);
            totalRevaultTvlBusd = totalRevaultTvlBusd.add(tvlDiff);
        }

        tokenInfo.tvlBusd = currTokenTvlBusd;

        if (tokenInfo.totalPrincipal > 0 && tokenInfo.tvlBusd > 0) {
            uint256 multiplier = (block.number).sub(tokenInfo.lastRewardBlock);
            uint256 revaReward = multiplier.mul(revaPerBlock).mul(tokenInfo.tvlBusd).div(totalRevaultTvlBusd);
            tokenInfo.accRevaPerToken = tokenInfo.accRevaPerToken.add(revaReward.mul(1e12).div(tokenInfo.totalPrincipal));
        }

        tokenInfo.lastRewardBlock = block.number;

        if (_isDeposit) tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.add(_amount);
        else tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.sub(_amount);
    }

    function claim(address token) external override {
        claimFor(token, msg.sender);
    }

    function claimFor(address token, address to) public override {
        updateRevaultRewards(token, 0, false);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][to];
        TokenInfo storage tokenInfo = tokens[token];

        uint pending = _calcPending(tokenInfo.accRevaPerToken, token, to);
        revaultUserInfo.pending = 0;
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        reva.mint(to, pending);
        emit RevaRewardPaid(to, token, pending);
    }

    /* ========== Private Functions ========== */

    function _calcPending(uint256 accRevaPerToken, address _tokenAddress, address _user) private view returns (uint256) {
        RevaultUserInfo storage revaultUserInfo = revaultUsers[_tokenAddress][_user];
        return revaultUserInfo.balance.mul(accRevaPerToken).div(1e12).sub(revaultUserInfo.rewardPaid).add(revaultUserInfo.pending);
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function claimTreasuryReward() external onlyTreasury {
        uint256 pendingRewards = block.number.sub(lastTreasuryRewardBlock).mul(revaTreasuryPerBlock);
        reva.mint(msg.sender, pendingRewards);
    }

    function setRevaPerBlock(uint256 _revaPerBlock) external onlyOwner {
        revaPerBlock = _revaPerBlock;
    }

    function setRevault(address _revaultAddress) external onlyOwner {
        revaultAddress = _revaultAddress;
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
    }

    function notifyDeposited(address user, address token, uint amount) external override onlyRevault  {
        updateRevaultRewards(token, amount, true);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][user];
        TokenInfo storage tokenInfo = tokens[token];

        uint pending = _calcPending(tokenInfo.accRevaPerToken, token, user);
        revaultUserInfo.pending = pending;
        revaultUserInfo.balance = revaultUserInfo.balance.add(amount);
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        emit NotifyDeposited(user, token, amount);
    }

    function notifyWithdrawn(address user, address token, uint amount) external override onlyRevault {
        updateRevaultRewards(token, amount, false);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][user];
        TokenInfo storage tokenInfo = tokens[token];

        uint pending = _calcPending(tokenInfo.accRevaPerToken, token, user);
        revaultUserInfo.pending = pending;
        revaultUserInfo.balance = revaultUserInfo.balance.sub(amount);
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        emit NotifyWithdrawn(user, token, amount);
    }

}
