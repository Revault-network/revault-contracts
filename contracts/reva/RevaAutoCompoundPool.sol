// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "../library/ReentrancyGuard.sol";
import "./interfaces/IvRevaToken.sol";
import "./interfaces/IRevaToken.sol";
import "./interfaces/IRevaStakingPool.sol";

contract RevaAutoCompoundPool is OwnableUpgradeable, ReentrancyGuard {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    // Info of each user that stakes reva tokens.
    mapping(uint => mapping(address => uint)) public userPoolShares;

    // Info of each pool.
    mapping(uint => uint) public totalPoolShares;

    address public revaToken;
    address public vRevaToken;
    address public revaStakingPool;

    function initialize(
        address _revaToken,
        address _vRevaToken,
        address _revaStakingPool
    ) external initializer {
        __Ownable_init();
        revaToken = _revaToken;
        vRevaToken = _vRevaToken;
        revaStakingPool = _revaStakingPool;
        IBEP20(revaToken).approve(revaStakingPool, uint(~0));
    }

    modifier revaStakingPoolOnly {
        require(msg.sender == revaStakingPool, "REVA STAKING POOL ONLY");
        _;
    }

    /* ========== External Functions ========== */

    // View function to see pending REVAs from Pools on frontend.
    function pendingReva(uint _pid, address _user) external view returns (uint) {
        uint userShares = userPoolShares[_pid][_user];
        uint totalShares = totalPoolShares[_pid];

        if (totalShares == 0) return 0;

        uint userBalance = balanceOf(_pid, _user);
        uint pendingPoolReva = IRevaStakingPool(revaStakingPool).pendingReva(_pid, address(this));
        uint pendingUserReva = pendingPoolReva.mul(userShares).div(totalShares);
        return userBalance.add(pendingUserReva);
    }

    function balance(uint _pid) public view returns (uint amount) {
        (amount,,,) = IRevaStakingPool(revaStakingPool).userPoolInfo(_pid, address(this));
    }

    function balanceOf(uint _pid, address _user) public view returns (uint) {
        uint userShares = userPoolShares[_pid][_user];
        uint totalShares = totalPoolShares[_pid];

        if (totalShares == 0) return 0;
        return balance(_pid).mul(userShares).div(totalShares);
    }

    function notifyDeposited(uint _pid, uint _amount, address _user) external revaStakingPoolOnly {
        uint userShares = userPoolShares[_pid][_user];
        uint totalShares = totalPoolShares[_pid];
        updatePool(_pid);

        uint poolBalance = balance(_pid);
        uint shares = 0;
        if (totalShares == 0) {
            shares = _amount;
        } else {
            shares = (_amount.mul(totalShares)).div(poolBalance.sub(_amount));
        }

        totalPoolShares[_pid] = totalShares.add(shares);
        userPoolShares[_pid][_user] = userShares.add(shares);
    }

    function enterCompoundingPosition(uint _pid) external nonReentrant {
        (uint userAmount,,,) = IRevaStakingPool(revaStakingPool).userPoolInfo(_pid, msg.sender);
        require(userAmount != 0, "User must have REVA staked");

        uint userShares = userPoolShares[_pid][msg.sender];
        uint totalShares = totalPoolShares[_pid];
        updatePool(_pid);

        uint poolBalance = balance(_pid);

        (uint prevAmount,,,) = IRevaStakingPool(revaStakingPool).userPoolInfo(_pid, address(this));
        IRevaStakingPool(revaStakingPool).enterCompoundingPosition(_pid, msg.sender);
        (uint postAmount,,,) = IRevaStakingPool(revaStakingPool).userPoolInfo(_pid, address(this));
        uint revaMigrated = postAmount.sub(prevAmount);

        uint shares = 0;
        if (totalShares == 0) {
            shares = revaMigrated;
        } else {
            shares = (revaMigrated.mul(totalShares)).div(poolBalance);
        }

        totalPoolShares[_pid] = totalShares.add(shares);
        userPoolShares[_pid][msg.sender] = userShares.add(shares);
    }

    function exitCompoundingPosition(uint _pid) external nonReentrant {
        updatePool(_pid);

        uint amount = balanceOf(_pid, msg.sender);
        IRevaStakingPool(revaStakingPool).exitCompoundingPosition(_pid, amount, msg.sender);

        totalPoolShares[_pid] = totalPoolShares[_pid].sub(userPoolShares[_pid][msg.sender]);
        userPoolShares[_pid][msg.sender] = 0;
    }

    function updatePool(uint _pid) public {
        // claim rewards from mint / fee reward by depositing 0
        IRevaStakingPool(revaStakingPool).deposit(_pid, 0);
        uint revaBalance = IBEP20(revaToken).balanceOf(address(this));
        // redeposit rewards just now collected and clear balance of this contract
        if (revaBalance > 0) {
            IRevaStakingPool(revaStakingPool).deposit(_pid, revaBalance);
        }
    }
}
