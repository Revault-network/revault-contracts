// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "./interfaces/IRevaStakingPool.sol";
import "./interfaces/IRevaAutoCompoundPool.sol";

contract RevaGovernance {
    using SafeMath for uint;

    address private constant VREVA = 0x774D9103dc027b707812aCF0e0B40A34DcAeF658;
    address private constant REVA_STAKING_POOL = 0x8B7b2a115201ACd7F95d874D6A9432FcEB9C466A;
    address private constant REVA_AUTOCOMPOUND_POOL = 0xe8f1CDa385A58ae1C1c1b71631dA7Ad6d137d3cb;

    constructor() public {}

    function balanceOf(address _account) external view returns (uint) {
        uint vRevaBalance = IBEP20(VREVA).balanceOf(_account);
        uint numOfPools = IRevaStakingPool(REVA_STAKING_POOL).poolLength();
        for (uint i = 0; i < numOfPools; i++) {
            (,, uint multiplier,,,,,) = IRevaStakingPool(REVA_STAKING_POOL).poolInfo(i);
            uint autocompoundBalance = IRevaAutoCompoundPool(REVA_AUTOCOMPOUND_POOL).balanceOf(i, _account);
            vRevaBalance  = vRevaBalance.add(autocompoundBalance.mul(multiplier));
        }
        return vRevaBalance;
    }

}
