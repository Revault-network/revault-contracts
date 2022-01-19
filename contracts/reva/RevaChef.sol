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
        uint256 balance;
        uint256 pending;
        uint256 rewardPaid;
    }

    struct TokenInfo {
        uint256 totalPrincipal;
        uint256 tvlBusd;
        uint256 lastRewardBlock;  // Last block number that REVAs distribution occurs.
        uint256 accRevaPerToken; // Accumulated REVAs per token deposited, times 1e12. See below.
        bool rewardsEnabled;
    }

    // The REVA TOKEN!
    RevaToken public reva;
    // zap
    IZap public zap;
    // revault address
    address public revaultAddress;
    // REVA tokens created per block.
    uint256 public revaPerBlock; 
    // treasury
    address public treasury;
    // admin
    address public admin;
    // REVA tokens created per block for treasury.
    uint256 public revaTreasuryPerBlock; 
    // checkpoint
    uint256 public lastTreasuryRewardBlock;
    // start block
    uint256 public startBlock;
    // The TVL of tokens combined
    uint256 public totalRevaultTvlBusd;
    // array of tokens deposited
    address[] public supportedTokens;

    // Info of each user that deposits through Revault
    mapping (address => mapping (address => RevaultUserInfo)) public revaultUsers;
    // mapping token address => token info
    mapping (address => TokenInfo) public tokens;

    uint256 public revaHoldingsMultiplier;
    // mapping token address => user address => pending reva burn 
    mapping (address => mapping (address => uint256)) public userPendingRevaBurn;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    event NotifyDeposited(address indexed user, address indexed token, uint amount);
    event NotifyWithdrawn(address indexed user, address indexed token, uint amount);
    event RevaRewardPaid(address indexed user, address indexed token, uint amount);
    event TreasuryRewardClaimed(uint amount);
    event SetRevaPerBlock(uint revaPerBlock);
    event SetRevaTreasuryPerBlock(uint revaTreasuryPerBlock);
    event SetRevault(address revaultAddress);
    event SetTreasury(address treasury);
    event SetAdmin(address admin);
    event TokenAdded(address token);
    event TokenRewardsDisabled(address token);
    event TokenRewardsEnabled(address token);

    function initialize(
        address _reva,
        address _zap,
        uint256 _revaPerBlock,
        uint256 _revaTreasuryPerBlock,
        address _treasury,
        uint256 _startBlock,
        address _admin
    ) external initializer {
        __Ownable_init();
        require(_startBlock >= block.number, "Start block must be in future");
        reva = RevaToken(_reva);
        zap = IZap(_zap);
        revaPerBlock = _revaPerBlock;
        revaTreasuryPerBlock = _revaTreasuryPerBlock;
        treasury = _treasury;
        lastTreasuryRewardBlock = _startBlock;
        startBlock = _startBlock;
        admin = _admin;
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

    modifier onlyOwnerOrAdmin {
        require(msg.sender == admin, "admin only");
        _;
    }

    /* ========== View Functions ========== */

    // View function to see pending REVAs from Revaults on frontend.
    function pendingReva(address _tokenAddress, address _user) external view returns (uint256) {
        TokenInfo memory tokenInfo = tokens[_tokenAddress];

        uint256 accRevaPerToken = tokenInfo.accRevaPerToken;
        if (block.number > tokenInfo.lastRewardBlock && tokenInfo.totalPrincipal != 0 && totalRevaultTvlBusd > 0 && tokenInfo.rewardsEnabled) {
            uint256 multiplier = (block.number).sub(tokenInfo.lastRewardBlock);
            uint256 revaReward = multiplier.mul(revaPerBlock).mul(tokenInfo.tvlBusd).div(totalRevaultTvlBusd);
            accRevaPerToken = accRevaPerToken.add(revaReward.mul(1e12).div(tokenInfo.totalPrincipal));
        }

        (uint pendingReward,) = _calcPending(accRevaPerToken, _tokenAddress, _user);
        return pendingReward;
    }

    function claim(address token) external override {
        claimFor(token, msg.sender);
    }

    function claimFor(address token, address to) public override {
        _updateRevaultRewards(token, 0, false);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][to];
        TokenInfo memory tokenInfo = tokens[token];

        (uint pendingReward, uint pendingBurn) = _calcPending(tokenInfo.accRevaPerToken, token, to);
        userPendingRevaBurn[token][to] = 0;
        revaultUserInfo.pending = 0;
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        reva.mint(to, pendingReward);
        reva.mint(DEAD, pendingBurn);
        emit RevaRewardPaid(to, token, pendingReward);
    }

    function updateAllTvls() external {
        require(msg.sender == tx.origin, "No flashloans");
        updateAllRevaultRewards();
        uint totalTvlBusd = 0;
        for (uint i = 0; i < supportedTokens.length; i++) {
            address tokenAddress = supportedTokens[i];
            TokenInfo storage tokenInfo = tokens[tokenAddress];
            if (tokenInfo.rewardsEnabled) {
                uint256 tokenTvlBusd = zap.getBUSDValue(tokenAddress, tokenInfo.totalPrincipal);
                tokenInfo.tvlBusd = tokenTvlBusd;
                totalTvlBusd = totalTvlBusd.add(tokenTvlBusd);
            }
        }
        totalRevaultTvlBusd = totalTvlBusd;
    }

    function updateRevaultRewards(uint tokenIdx) external {
        address tokenAddress = supportedTokens[tokenIdx];
        _updateRevaultRewards(tokenAddress, 0, false);
    }

    function updateAllRevaultRewards() public {
        for (uint i = 0; i < supportedTokens.length; i++) {
            _updateRevaultRewards(supportedTokens[i], 0, false);
        }
    }

    function getSupportedTokensCount() external view returns (uint256) {
      return supportedTokens.length;
    }

    /* ========== Private Functions ========== */

    function _updateRevaultRewards(address _tokenAddress, uint256 _amount, bool _isDeposit) internal {
        TokenInfo storage tokenInfo = tokens[_tokenAddress];
        if (block.number <= tokenInfo.lastRewardBlock) {
            if (_isDeposit) tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.add(_amount);
            else tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.sub(_amount);
            return;
        }

        // NOTE: this is done so that a new token won't get too many rewards
        if (tokenInfo.lastRewardBlock == 0) {
            // only revault contract can add new tokens, dos protection
            require(msg.sender == revaultAddress, "ORV");
            tokenInfo.lastRewardBlock = block.number > startBlock ? block.number : startBlock;
            tokenInfo.rewardsEnabled = true;
            supportedTokens.push(_tokenAddress);
            emit TokenAdded(_tokenAddress);
        } else {
            if (tokenInfo.totalPrincipal > 0 && totalRevaultTvlBusd > 0 && tokenInfo.rewardsEnabled) {
                uint256 multiplier = (block.number).sub(tokenInfo.lastRewardBlock);
                uint256 revaReward = multiplier.mul(revaPerBlock).mul(tokenInfo.tvlBusd).div(totalRevaultTvlBusd);
                tokenInfo.accRevaPerToken = tokenInfo.accRevaPerToken.add(revaReward.mul(1e12).div(tokenInfo.totalPrincipal));
            }

            tokenInfo.lastRewardBlock = block.number;
        }

        if (_isDeposit) tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.add(_amount);
        else tokenInfo.totalPrincipal = tokenInfo.totalPrincipal.sub(_amount);
    }

    function _calcPending(uint256 accRevaPerToken, address _tokenAddress, address _user) private view returns (uint256, uint256) {
        RevaultUserInfo memory revaultUserInfo = revaultUsers[_tokenAddress][_user];
        TokenInfo memory tokenInfo = tokens[_tokenAddress];

        uint256 revaBalance = reva.balanceOf(_user);
        uint256 maxTvlRewards = revaBalance.mul(revaHoldingsMultiplier);
        uint256 userTokenTvlBusd = revaultUserInfo.balance.mul(tokenInfo.tvlBusd).div(tokenInfo.totalPrincipal);
        return _calcRewards(accRevaPerToken, _tokenAddress, _user, maxTvlRewards, userTokenTvlBusd);
    }

    function _calcRewards(
        uint256 accRevaPerToken,
        address _tokenAddress,
        address _user,
        uint256 _maxTvlRewards,
        uint256 _userTokenTvlBusd
    ) private view returns (uint256, uint256) {
        RevaultUserInfo memory revaultUserInfo = revaultUsers[_tokenAddress][_user];
        uint256 pendingBurn = userPendingRevaBurn[_tokenAddress][_user];

        uint256 newReward = revaultUserInfo.balance.mul(accRevaPerToken).div(1e12).sub(revaultUserInfo.rewardPaid);
        // if user has enough reva holdings to get max rewards, give full rewards
        if (_maxTvlRewards >= _userTokenTvlBusd) {
            uint256 finalReward = newReward.add(revaultUserInfo.pending);
            return (finalReward, pendingBurn);
        } else {
            uint256 cappedNewReward = newReward.mul(_maxTvlRewards).div(_userTokenTvlBusd);
            uint256 finalReward = cappedNewReward.add(revaultUserInfo.pending);
            uint256 finalPendingBurn = newReward.sub(cappedNewReward).add(pendingBurn);
            return (finalReward, finalPendingBurn);
        }
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function claimTreasuryReward() external onlyTreasury {
        uint256 pendingRewards = block.number.sub(lastTreasuryRewardBlock).mul(revaTreasuryPerBlock);
        reva.mint(msg.sender, pendingRewards);
        lastTreasuryRewardBlock = block.number;
        emit TreasuryRewardClaimed(pendingRewards);
    }

    function disableTokenRewards(uint tokenIdx) external onlyOwnerOrAdmin {
        address tokenAddress = supportedTokens[tokenIdx];
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        require(tokenInfo.rewardsEnabled, "token rewards already disabled");

        updateAllRevaultRewards();
        totalRevaultTvlBusd = totalRevaultTvlBusd.sub(tokenInfo.tvlBusd);
        tokenInfo.tvlBusd = 0;

        tokenInfo.rewardsEnabled = false;
        emit TokenRewardsDisabled(tokenAddress);
    }

    function enableTokenRewards(uint tokenIdx) external onlyOwnerOrAdmin {
        address tokenAddress = supportedTokens[tokenIdx];
        TokenInfo storage tokenInfo = tokens[tokenAddress];
        require(!tokenInfo.rewardsEnabled, "token rewards already enabled");

        updateAllRevaultRewards();
        uint256 tokenTvlBusd = zap.getBUSDValue(tokenAddress, tokenInfo.totalPrincipal);
        tokenInfo.tvlBusd = tokenTvlBusd;
        totalRevaultTvlBusd = totalRevaultTvlBusd.add(tokenTvlBusd);

        tokenInfo.rewardsEnabled = true;
        emit TokenRewardsEnabled(tokenAddress);
    }

    function setRevaPerBlock(uint256 _revaPerBlock) external onlyOwner {
        revaPerBlock = _revaPerBlock;
        emit SetRevaPerBlock(_revaPerBlock);
    }

    function setRevaTreasuryPerBlock(uint256 _revaTreasuryPerBlock) external onlyOwner {
        revaTreasuryPerBlock = _revaTreasuryPerBlock;
        emit SetRevaTreasuryPerBlock(_revaTreasuryPerBlock);
    }

    function setRevault(address _revaultAddress) external onlyOwner {
        revaultAddress = _revaultAddress;
        emit SetRevault(_revaultAddress);
    }

    function setTreasury(address _treasury) external onlyOwner {
        treasury = _treasury;
        emit SetTreasury(_treasury);
    }

    function setAdmin(address _admin) external onlyOwnerOrAdmin {
        admin = _admin;
        emit SetAdmin(_admin);
    }

    function setRevaHoldingsMultiplier(uint256 _revaHoldingsMultiplier) external onlyOwnerOrAdmin {
        revaHoldingsMultiplier = _revaHoldingsMultiplier;
    }

    function notifyDeposited(address user, address token, uint amount) external override onlyRevault  {
        _updateRevaultRewards(token, amount, true);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][user];
        TokenInfo memory tokenInfo = tokens[token];

        (uint pendingReward, uint pendingBurn) = _calcPending(tokenInfo.accRevaPerToken, token, user);
        userPendingRevaBurn[token][user] = pendingBurn;
        revaultUserInfo.pending = pendingReward;
        revaultUserInfo.balance = revaultUserInfo.balance.add(amount);
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        emit NotifyDeposited(user, token, amount);
    }

    function notifyWithdrawn(address user, address token, uint amount) external override onlyRevault {
        _updateRevaultRewards(token, amount, false);
        RevaultUserInfo storage revaultUserInfo = revaultUsers[token][user];
        TokenInfo memory tokenInfo = tokens[token];

        (uint pendingReward, uint pendingBurn) = _calcPending(tokenInfo.accRevaPerToken, token, user);
        userPendingRevaBurn[token][user] = pendingBurn;
        revaultUserInfo.pending = pendingReward;
        revaultUserInfo.balance = revaultUserInfo.balance.sub(amount);
        revaultUserInfo.rewardPaid = revaultUserInfo.balance.mul(tokenInfo.accRevaPerToken).div(1e12);
        emit NotifyWithdrawn(user, token, amount);
    }

}
