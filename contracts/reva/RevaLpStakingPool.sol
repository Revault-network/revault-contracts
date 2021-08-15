// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "./interfaces/IvRevaToken.sol";
import "./interfaces/IRevaToken.sol";

contract RevaLpStakingPool is OwnableUpgradeable {
    using SafeMath for uint;

    struct UserPoolInfo {
        uint amount;     // How many LP tokens the user has provided.
        uint rewardDebt; // Reward debt. See explanation below.
        uint rewardFeeDebt; // Reward debt. See explanation below.
    }

    // Info of each pool.
    struct PoolInfo {
        address lpToken;
        uint totalSupply;
        uint allocPoint;       // How many allocation points assigned to this pool. REVAs to distribute per block.
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
    uint public revaPerBlock;
    uint public startBlock;

    uint public accWithdrawnRevaFromFees;
    uint public accRevaFromFees;
    uint public lastUpdatedRevaFeesBlock;

    // Total allocation points. Must be the sum of all allocation points in all pools.
    uint public totalAllocPoint = 0;

    event Deposit(address indexed user, uint indexed pid, uint amount);
    event Withdraw(address indexed user, uint indexed pid, uint amount);
    event EmergencyWithdraw(address indexed user, uint indexed pid, uint amount);

    function initialize(
        address _revaToken,
        address _revaFeeReceiver,
        uint _revaPerBlock,
        uint _startBlock
    ) external initializer {
        __Ownable_init();
        revaToken = _revaToken;
        revaFeeReceiver = _revaFeeReceiver;
        revaPerBlock = _revaPerBlock;
        startBlock = _startBlock;
    }

    function poolLength() external view returns (uint) {
        return poolInfo.length;
    }

    // View function to see pending REVAs from Pools on frontend.
    // TODO take into account fees
    function pendingReva(uint _pid, address _user) external view returns (uint) {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][_user];
        uint accRevaPerShare = pool.accRevaPerShare;
        if (block.number > pool.lastRewardBlock && pool.totalSupply != 0) {
            uint multiplier = (block.number).sub(pool.lastRewardBlock);
            uint revaReward = multiplier.mul(revaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
            accRevaPerShare = accRevaPerShare.add(revaReward.mul(1e12).div(pool.totalSupply));
        }
        return user.amount.mul(accRevaPerShare).div(1e12).sub(user.rewardDebt);
    }

    /* ========== External Functions ========== */

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
        if (block.number <= lastUpdatedRevaFeesBlock) {
            uint revaReceived = IBEP20(revaToken).balanceOf(revaFeeReceiver).add(accWithdrawnRevaFromFees).sub(accRevaFromFees);
            if (revaReceived > 0) {
                accRevaFromFees = accRevaFromFees.add(revaReceived);
            }
            lastUpdatedRevaFeesBlock = block.number;
        }
        if (pool.lastAccRevaFromFees <= accRevaFromFees) {
            uint revaFeeReward = accRevaFromFees.sub(pool.lastAccRevaFromFees).mul(pool.allocPoint).div(totalAllocPoint);
            pool.accRevaPerShareFromFees = pool.accRevaPerShareFromFees.add(revaFeeReward.mul(1e12).div(pool.totalSupply));
            pool.lastAccRevaFromFees = accRevaFromFees;
        }
        uint multiplier = (block.number).sub(pool.lastRewardBlock);
        uint revaReward = multiplier.mul(revaPerBlock).mul(pool.allocPoint).div(totalAllocPoint);
        pool.accRevaPerShare = pool.accRevaPerShare.add(revaReward.mul(1e12).div(pool.totalSupply));
        pool.lastRewardBlock = block.number;
    }

    // Deposit LP tokens to MasterChef for REVA allocation.
    function deposit(uint _pid, uint _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        updatePool(_pid);
        if (user.amount > 0) {
            uint pendingMintReward = user.amount.mul(pool.accRevaPerShare).div(1e12).sub(user.rewardDebt);
            IRevaToken(revaToken).mint(msg.sender, pendingMintReward);
            uint pendingFeeReward = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
            if (pendingFeeReward > 0) {
                accWithdrawnRevaFromFees = accWithdrawnRevaFromFees.add(pendingFeeReward);
                IBEP20(revaToken).transferFrom(revaFeeReceiver, msg.sender, pendingFeeReward);
            }
        }
        if (_amount > 0) {
            uint before = IBEP20(pool.lpToken).balanceOf(address(this));
            IBEP20(pool.lpToken).transferFrom(address(msg.sender), address(this), _amount);
            uint post = IBEP20(pool.lpToken).balanceOf(address(this));
            uint finalAmount = post.sub(before);
            user.amount = user.amount.add(finalAmount);
            pool.totalSupply = pool.totalSupply.add(finalAmount);
            emit Deposit(msg.sender, _pid, finalAmount);
        }
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
    }

    // Withdraw LP tokens from MasterChef.
    function withdraw(uint _pid, uint _amount) external {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        require(user.amount >= _amount, "withdraw: not good");

        updatePool(_pid);
        uint pendingMintReward = user.amount.mul(pool.accRevaPerShare).div(1e12).sub(user.rewardDebt);
        if (pendingMintReward > 0) {
            IRevaToken(revaToken).mint(msg.sender, pendingMintReward);
        }
        uint pendingFeeReward = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12).sub(user.rewardFeeDebt);
        if (pendingFeeReward > 0) {
            accWithdrawnRevaFromFees = accWithdrawnRevaFromFees.add(pendingFeeReward);
            IBEP20(revaToken).transferFrom(revaFeeReceiver, msg.sender, pendingFeeReward);
        }
        if(_amount > 0) {
            user.amount = user.amount.sub(_amount);
            pool.totalSupply = pool.totalSupply.sub(_amount);
            IBEP20(pool.lpToken).transfer(address(msg.sender), _amount);
        }
        user.rewardDebt = user.amount.mul(pool.accRevaPerShare).div(1e12);
        user.rewardFeeDebt = user.amount.mul(pool.accRevaPerShareFromFees).div(1e12);
        emit Withdraw(msg.sender, _pid, _amount);
    }

    // Withdraw without caring about rewards. EMERGENCY ONLY.
    function emergencyWithdraw(uint _pid) public {
        PoolInfo storage pool = poolInfo[_pid];
        UserPoolInfo storage user = userPoolInfo[_pid][msg.sender];
        IBEP20(pool.lpToken).transfer(address(msg.sender), user.amount);
        emit EmergencyWithdraw(msg.sender, _pid, user.amount);
        pool.totalSupply = pool.totalSupply.sub(user.amount);
        user.amount = 0;
        user.rewardDebt = 0;
        user.rewardFeeDebt = 0;
    }

    // Update reward variables for all pools. Be careful of gas spending!
    function massUpdatePools() public {
        uint length = poolInfo.length;
        for (uint pid = 0; pid < length; ++pid) {
            updatePool(pid);
        }
    }

    // Add a new lp to the pool. Can only be called by the owner.
    // XXX DO NOT add the same LP token more than once. Rewards will be messed up if you do.
    function add(uint _allocPoint, address _lpToken, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint lastRewardBlock = block.number > startBlock ? block.number : startBlock;
        totalAllocPoint = totalAllocPoint.add(_allocPoint);
        poolInfo.push(PoolInfo({
            lpToken: _lpToken,
            totalSupply: 0,
            allocPoint: _allocPoint,
            lastRewardBlock: lastRewardBlock,
            accRevaPerShare: 0,
            accRevaPerShareFromFees: 0,
            lastAccRevaFromFees: accRevaFromFees
        }));
    }

    // Update the given pool's REVA allocation point. Can only be called by the owner.
    function set(uint _pid, uint _allocPoint, bool _withUpdate) public onlyOwner {
        if (_withUpdate) {
            massUpdatePools();
        }
        uint prevAllocPoint = poolInfo[_pid].allocPoint;
        poolInfo[_pid].allocPoint = _allocPoint;
        if (prevAllocPoint != _allocPoint) {
            totalAllocPoint = totalAllocPoint.sub(prevAllocPoint).add(_allocPoint);
        }
    }

    function setRevaPerBlock(uint _revaPerBlock) external onlyOwner {
        revaPerBlock = _revaPerBlock;
    }

}

