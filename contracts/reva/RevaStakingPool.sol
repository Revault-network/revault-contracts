// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "../library/ReentrancyGuard.sol";
import "./interfaces/IvRevaToken.sol";
import "./interfaces/IRevaToken.sol";
import "./interfaces/IRevaAutoCompoundPool.sol";

contract RevaStakingPool is OwnableUpgradeable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    struct UserPoolInfo {
        uint amount;     // How many LP tokens the user has provided.
        uint rewardDebt; // Reward debt. See explanation below.
        uint rewardFeeDebt; // Reward debt. See explanation below.
        uint timeDeposited;
    }

    // Info of each pool.
    struct PoolInfo {
        uint totalSupply;
        uint allocPoint;       // How many allocation points assigned to this pool. REVAs to distribute per block.
        uint vRevaMultiplier;
        uint timeLocked;       // How long stake must be locked for
        uint lastRewardBlock;  // Last block number that REVAs distribution occurs.
        uint accRevaPerShare; // Accumulated REVAs per share, times 1e12. See below.
        uint accRevaPerShareFromFees; // Accumulated REVAs per share, times 1e12. See below.
        uint lastAccRevaFromFees; // last recorded total accumulated reva from fees
    }

    // Info of each pool.
    PoolInfo[] public poolInfo;
    // Info of each user that stakes LP tokens.
    mapping (uint => mapping (address => UserPoolInfo)) public userPoolInfo;

    address public revaFeeReceiver;
    address public revaToken;
    address public vRevaToken;
    uint public revaPerBlock;
    uint public startBlock;

    uint public accWithdrawnRevaFromFees;
    uint public accRevaFromFees;
    uint public lastUpdatedRevaFeesBlock;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint;

    uint public earlyWithdrawalFee;
    uint public constant EARLY_WITHDRAWAL_FEE_PRECISION = 1000000;
    uint public constant MAX_EARLY_WITHDRAWAL_FEE = 500000;

    // variables for autocompounding upgrade
    address public revaAutoCompoundPool;
    mapping (uint => mapping (address => bool)) public userIsCompounding;

    event VRevaMinted(address indexed user, uint indexed pid, uint amount);
    event VRevaBurned(address indexed user, uint indexed pid, uint amount);
    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EarlyWithdrawal(address indexed user, uint indexed pid, uint amount, uint withdrawalFee);
    event EmergencyWithdrawEarly(address indexed user, uint indexed pid, uint amount, uint withdrawalFee);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);
    event PoolAdded(uint allocPoint, uint vRevaMultiplier, uint timeLocked);
    event SetRevaPerBlock(uint revaPerBlock);
    event SetEarlyWithdrawalFee(uint earlyWithdrawalFee);
    event SetPool(uint pid, uint allocPoint);
    event SetRevaAutoCompoundPool(address _revaAutoCompoundPool);
    event CompoundingEnabled(address indexed user, uint pid, bool enabled);

    function initialize(
        address _revaToken,
        address _vRevaToken,
        address _revaFeeReceiver,
        uint _revaPerBlock,
        uint _startBlock,
        uint _earlyWithdrawalFee
    ) external initializer {
        __Ownable_init();
        require(_earlyWithdrawalFee <= MAX_EARLY_WITHDRAWAL_FEE, "MAX_EARLY_WITHDRAWAL_FEE");
        revaToken = _revaToken;
        vRevaToken = _vRevaToken;
        revaFeeReceiver = _revaFeeReceiver;
        revaPerBlock = _revaPerBlock;
        startBlock = _startBlock;
        earlyWithdrawalFee = _earlyWithdrawalFee;

        // staking pool
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 1000,
            vRevaMultiplier: 1,
            timeLocked: 0 days,
            lastRewardBlock: startBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 2000,
            vRevaMultiplier: 2,
            timeLocked: 7 days,
            lastRewardBlock: startBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 3000,
            vRevaMultiplier: 3,
            timeLocked: 30 days,
            lastRewardBlock: startBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: 0
        }));
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: 4000,
            vRevaMultiplier: 4,
            timeLocked: 90 days,
            lastRewardBlock: startBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: 0
        }));
        totalAllocPoint = 10000;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    modifier revaAutoCompoundPoolOnly {
        require(msg.sender == revaAutoCompoundPool, "AUTO COMPOUND POOL ONLY");
        _;
    }

    /* ========== External Functions ========== */

    // View function to see pending REVAs from Pools on frontend.
    function pendingReva(uint _pid, address _user) external view returns (uint) {
        PoolInfo memory pool = poolInfo[_pid];
        UserPoolInfo memory user = userPoolInfo[_pid][_user];

        // Minting reward
        uint accRevaPerShare = pool.accRevaPerShare;
        if (block.number > pool.lastRewardBlock && pool.totalSupply != 0) {
            uint multiplier = (block.number).sub(pool.lastRewardBlock);
            uint revaReward = multiplier.mul(revaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accRevaPerShare = accRevaPerShare.add(revaReward.mul(1e12).div(pool.totalSupply));
        }
        uint pendingUserReva = user.amount.mul(accRevaPerShare).div(1e12).sub(user.rewardDebt);

        // Transfer fee rewards
        uint _accRevaFromFees = accRevaFromFees;
        if (block.number > lastUpdatedRevaFeesBlock) {
            uint revaReceived = IBEP20(revaToken).balanceOf(revaFeeReceiver).add(accWithdrawnRevaFromFees);
            if (revaReceived.sub(_accRevaFromFees) > 0) {
                _accRevaFromFees = revaReceived;
            }
        }
        if (pool.lastAccRevaFromFees < _accRevaFromFees && pool.totalSupply != 0) {
            uint revaFeeReward = _accRevaFromFees.sub(pool.lastAccRevaFromFees).mul(pool.allocPoint).div(totalAllocPoint);
            uint accRevaPerShareFromFees = pool.accRevaPerShareFromFees.add(revaFeeReward.mul(1e12).div(pool.totalSupply));
            uint pendingFeeReward = user.amount.mul(accRevaPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
            pendingUserReva = pendingUserReva.add(pendingFeeReward);
        }

        return pendingUserReva;
    }

    // Update reward variables of the given pool to be up-to-date.
    function updatePool(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        if (block.number <= pool.lastRewardBlock) {
            return;
        }
        if (pool.totalSupply == 0) {
            pool.lastRewardBlock = block.number;
            return;
        }

        // Minting reward
        if (block.number > pool.lastRewardBlock && pool.totalSupply != 0) {
          uint multiplier = (block.number).sub(pool.lastRewardBlock);
          uint revaReward = multiplier.mul(revaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
          pool.accRevaPerShare = pool.accRevaPerShare.add(revaReward.mul(1e12).div(pool.totalSupply));
          pool.lastRewardBlock = block.number;
        }

        // Transfer fee rewards
        if (block.number > lastUpdatedRevaFeesBlock) {
            uint revaReceived = IBEP20(revaToken).balanceOf(revaFeeReceiver).add(accWithdrawnRevaFromFees);
            if (revaReceived.sub(accRevaFromFees) > 0) {
                accRevaFromFees = revaReceived;
            }
            lastUpdatedRevaFeesBlock = block.number;
        }
        if (pool.lastAccRevaFromFees < accRevaFromFees && pool.totalSupply != 0) {
            uint revaFeeReward = accRevaFromFees.sub(pool.lastAccRevaFromFees).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accRevaPerShareFromFees = pool.accRevaPerShareFromFees.add(revaFeeReward.mul(1e12).div(pool.totalSupply));
            pool.lastAccRevaFromFees = accRevaFromFees;
        }
    }

    // Deposit REVA tokens for REVA allocation.
    function deposit(uint _pid, uint _amount) external nonReentrant {
        require(!userIsCompounding[_pid][msg.sender], "Can't deposit when compounding");
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            _claimPendingMintReward(_pid, msg.sender);
            _claimPendingFeeReward(_pid, msg.sender);
        }
        if (_amount > 0) {
            uint before = IBEP20(revaToken).balanceOf(address(this));
            IBEP20(revaToken).safeTransferFrom(address(msg.sender), address(this), _amount);
            uint post = IBEP20(revaToken).balanceOf(address(this));
            uint finalAmount = post.sub(before);
            uint vRevaToMint = pool.vRevaMultiplier.mul(finalAmount);
            IvRevaToken(vRevaToken).mint(msg.sender, vRevaToMint);
            user.amount = user.amount.add(finalAmount);
            user.timeDeposited = block.timestamp;
            pool.totalSupply = pool.totalSupply.add(finalAmount);
            emit VRevaMinted(msg.sender, _pid, vRevaToMint);
            emit Deposit(msg.sender, _pid, finalAmount);
        }
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
    }

    // Withdraw LP tokens
    function withdraw(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");
        require(block.timestamp >= user.timeDeposited.add(pool.timeLocked), "time locked");

        updatePool(_pid);
        _claimPendingMintReward(_pid, msg.sender);
        _claimPendingFeeReward(_pid, msg.sender);

        if(_amount > 0) {
            uint vRevaToBurn = pool.vRevaMultiplier.mul(_amount);
            IvRevaToken(vRevaToken).burn(msg.sender, vRevaToBurn);
            emit VRevaBurned(msg.sender, _pid, vRevaToBurn);
            user.amount = user.amount.sub(_amount);
            pool.totalSupply = pool.totalSupply.sub(_amount);
            IBEP20(revaToken).safeTransfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    function withdrawEarly(uint _pid, uint _amount) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        updatePool(_pid);

        _claimPendingMintReward(_pid, msg.sender);
        _claimPendingFeeReward(_pid, msg.sender);

        require(block.timestamp < user.timeDeposited.add(pool.timeLocked), "Not early");
        uint withdrawalFee = _amount.mul(earlyWithdrawalFee).div(EARLY_WITHDRAWAL_FEE_PRECISION);
        IBEP20(revaToken).safeTransfer(address(msg.sender), _amount.sub(withdrawalFee));
        IBEP20(revaToken).safeTransfer(revaFeeReceiver, withdrawalFee);

        uint vRevaToBurn = pool.vRevaMultiplier.mul(_amount);
        IvRevaToken(vRevaToken).burn(msg.sender, vRevaToBurn);
        emit VRevaBurned(msg.sender, _pid, vRevaToBurn);

        user.amount = user.amount.sub(_amount);
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
        pool.totalSupply = pool.totalSupply.sub(_amount);
        emit EarlyWithdrawal(msg.sender, _pid, _amount, withdrawalFee);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(block.timestamp >= user.timeDeposited.add(pool.timeLocked), "time locked");

        uint vRevaToBurn = pool.vRevaMultiplier.mul(user.amount);
        uint amount = user.amount;

        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardFeeDebt = 0;

        IvRevaToken(vRevaToken).burn(msg.sender, vRevaToBurn);
        IBEP20(revaToken).safeTransfer(address(msg.sender), amount);
        emit VRevaBurned(msg.sender, _pid, vRevaToBurn);
        emit EmergencyWithdraw(msg.sender, _pid, amount);
    }

    // Withdraw early without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdrawEarly(uint _pid) external nonReentrant {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];

        uint withdrawalFee = user.amount.mul(earlyWithdrawalFee).div(EARLY_WITHDRAWAL_FEE_PRECISION);
        uint vRevaToBurn = pool.vRevaMultiplier.mul(user.amount);
        uint amount = user.amount;

        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardFeeDebt = 0;

        IvRevaToken(vRevaToken).burn(msg.sender, vRevaToBurn);
        IBEP20(revaToken).safeTransfer(address(msg.sender), amount.sub(withdrawalFee));
        IBEP20(revaToken).safeTransfer(revaFeeReceiver, withdrawalFee);

        emit VRevaBurned(msg.sender, _pid, vRevaToBurn);
        emit EmergencyWithdrawEarly(msg.sender, _pid, amount, withdrawalFee);
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    function enterCompoundingPosition(uint _pid, address _user) external nonReentrant revaAutoCompoundPoolOnly {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];
        UserPoolInfo storage revaAutoCompoundInfo = userPoolInfo[_pid][revaAutoCompoundPool];
        uint migrationAmount = user.amount;

        if (user.amount > 0) {
            _claimPendingMintReward(_pid, _user);
            _claimPendingFeeReward(_pid, _user);
        }
        if (revaAutoCompoundInfo.amount > 0) {
            _claimPendingMintReward(_pid, revaAutoCompoundPool);
            _claimPendingFeeReward(_pid, revaAutoCompoundPool);
        }

        user.amount = 0;
        revaAutoCompoundInfo.amount = revaAutoCompoundInfo.amount.add(migrationAmount);
        revaAutoCompoundInfo.rewardDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShare).div(1e12);
        revaAutoCompoundInfo.rewardFeeDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
        revaAutoCompoundInfo.timeDeposited = block.timestamp;

        userIsCompounding[_pid][_user] = true;
        emit CompoundingEnabled(_user, _pid, true);

        uint vRevaToMint = pool.vRevaMultiplier.mul(migrationAmount);
        IvRevaToken(vRevaToken).mint(revaAutoCompoundPool, vRevaToMint);
        emit VRevaMinted(_user, _pid, vRevaToMint);
        IvRevaToken(vRevaToken).burn(_user, vRevaToMint);
        emit VRevaBurned(_user, _pid, vRevaToMint);
    }

    function exitCompoundingPosition(uint _pid, uint _amount, address _user) external nonReentrant revaAutoCompoundPoolOnly {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];
        UserPoolInfo storage revaAutoCompoundInfo = userPoolInfo[_pid][revaAutoCompoundPool];

        if (user.amount > 0) {
            _claimPendingMintReward(_pid, _user);
            _claimPendingFeeReward(_pid, _user);
        }
        if (revaAutoCompoundInfo.amount > 0) {
            _claimPendingMintReward(_pid, revaAutoCompoundPool);
            _claimPendingFeeReward(_pid, revaAutoCompoundPool);
        }

        revaAutoCompoundInfo.amount = revaAutoCompoundInfo.amount.sub(_amount);
        revaAutoCompoundInfo.rewardDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShare).div(1e12);
        revaAutoCompoundInfo.rewardFeeDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShareFromFees).div(1e12);

        user.amount = user.amount.add(_amount);
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
        user.timeDeposited = block.timestamp;

        userIsCompounding[_pid][_user] = false;
        emit CompoundingEnabled(_user, _pid, false);

        uint vRevaToMint = pool.vRevaMultiplier.mul(_amount);
        IvRevaToken(vRevaToken).mint(_user, vRevaToMint);
        emit VRevaMinted(_user, _pid, vRevaToMint);
        IvRevaToken(vRevaToken).burn(revaAutoCompoundPool, vRevaToMint);
        emit VRevaBurned(revaAutoCompoundPool, _pid, vRevaToMint);
    }

    function depositToCompoundingPosition(uint _pid, uint _amount) external {
        updatePool(_pid);
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        UserPoolInfo storage revaAutoCompoundInfo = userPoolInfo[_pid][revaAutoCompoundPool];

        require(user.amount == 0, "Can't compound when deposited");
        require(_amount > 0, "Must deposit non zero amount");

        if (revaAutoCompoundInfo.amount > 0) {
            _claimPendingMintReward(_pid, revaAutoCompoundPool);
            _claimPendingFeeReward(_pid, revaAutoCompoundPool);
        }

        uint before = IBEP20(revaToken).balanceOf(address(this));
        IBEP20(revaToken).safeTransferFrom(address(msg.sender), address(this), _amount);
        uint post = IBEP20(revaToken).balanceOf(address(this));
        uint finalAmount = post.sub(before);
        uint vRevaToMint = pool.vRevaMultiplier.mul(finalAmount);
        IvRevaToken(vRevaToken).mint(revaAutoCompoundPool, vRevaToMint);
        emit VRevaMinted(revaAutoCompoundPool, _pid, vRevaToMint);

        revaAutoCompoundInfo.amount = revaAutoCompoundInfo.amount.add(finalAmount);
        revaAutoCompoundInfo.timeDeposited = block.timestamp;
        revaAutoCompoundInfo.rewardDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShare).div(1e12);
        revaAutoCompoundInfo.rewardFeeDebt = revaAutoCompoundInfo.amount.mul(pool.accRevaPerShareFromFees).div(1e12);

        pool.totalSupply = pool.totalSupply.add(finalAmount);

        userIsCompounding[_pid][msg.sender] = true;

        IRevaAutoCompoundPool(revaAutoCompoundPool).notifyDeposited(_pid, finalAmount, msg.sender);
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint _allocPoint, uint _vRevaMultiplier, uint _timeLocked) external onlyOwner {
        massUpdatePools();
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            totalSupply: 0,
            allocPoint: _allocPoint,
            vRevaMultiplier: _vRevaMultiplier,
            timeLocked: _timeLocked,
            lastRewardBlock: lastRewardBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: accRevaFromFees
        }));
        emit PoolAdded(_allocPoint, _vRevaMultiplier, _timeLocked);
    }

    // Update the given pool's REVA allocation point. Can only be called by the owner.
    function set(uint _pid, uint _allocPoint) external onlyOwner {
        massUpdatePools();
        uint prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
        emit SetPool(_pid, _allocPoint);
    }

    function setRevaPerBlock(uint _revaPerBlock) external onlyOwner {
        revaPerBlock = _revaPerBlock;
        emit SetRevaPerBlock(_revaPerBlock);
    }

    function setEarlyWithdrawalFee(uint _earlyWithdrawalFee) external onlyOwner {
        require(_earlyWithdrawalFee <= MAX_EARLY_WITHDRAWAL_FEE, "MAX_EARLY_WITHDRAWAL_FEE");
        earlyWithdrawalFee = _earlyWithdrawalFee;
        emit SetEarlyWithdrawalFee(earlyWithdrawalFee);
    }

    function setRevaAutoCompoundPool(address _revaAutoCompoundPool) external onlyOwner {
        revaAutoCompoundPool = _revaAutoCompoundPool;
        emit SetRevaAutoCompoundPool(_revaAutoCompoundPool);
    }

    function _claimPendingMintReward(uint _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];

        uint pendingMintReward = user.amount.mul(pool.accRevaPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingMintReward > 0) {
            IRevaToken(revaToken).mint(_user, pendingMintReward);
        }
    }

    function _claimPendingFeeReward(uint _pid, address _user) private {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];

        uint pendingFeeReward = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
        if (pendingFeeReward > 0) {
            accWithdrawnRevaFromFees = accWithdrawnRevaFromFees.add(pendingFeeReward);
            transferFromFeeReceiver(_user, pendingFeeReward);
        }
    }

    function transferFromFeeReceiver(address to, uint amount) private {
        uint balance = IBEP20(revaToken).balanceOf(revaFeeReceiver);
        if (balance < amount) amount = balance;
        IBEP20(revaToken).safeTransferFrom(revaFeeReceiver, to, amount);
    }

}
