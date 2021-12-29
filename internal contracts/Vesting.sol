//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";

contract Vesting is Ownable {
    using SafeMath for uint;

    struct ShareHolder {
        address mainAccount;
        address emergencyAccount;
        uint shares;
        uint claimedTokens;
    }

    bool public started;

    address public shareholderToken;
    uint public totalTokens;

    uint public currentShares;
    uint public constant maxShares = 1000000;
    uint public unlockedPortions = 0;
    uint public totalPortions;

    ShareHolder[] public shareHolders;
    uint[] public vestingTimes;

    constructor(address _shareholderToken, uint[] memory _vestingTimes) public {
        shareholderToken = _shareholderToken;
        vestingTimes = _vestingTimes;
        totalPortions = vestingTimes.length;
    }

    function claimableTokens(uint holderIdx) public view returns (uint) {
        ShareHolder memory shareHolder = shareHolders[holderIdx];
        uint totalUserClaimable = totalTokens.mul(shareHolder.shares).mul(unlockedPortions).div(totalPortions).div(maxShares);
        uint totalUserAvailable = totalUserClaimable.sub(shareHolder.claimedTokens);
        return totalUserAvailable;
    }

    function start() external onlyOwner {
        require(!started, "STARTED");
        require(currentShares == maxShares, "SHARES");
        totalTokens = IBEP20(shareholderToken).balanceOf(address(this));
        require(totalTokens > 0, "BALANCE");
        started = true;
    }

    function addShareHolder(
        address mainAccount,
        address emergencyAccount,
        uint shares
    ) external onlyOwner {
        require(currentShares.add(shares) <= maxShares, "MAX_SHARES");
        currentShares = currentShares.add(shares);
        shareHolders.push(ShareHolder({
            mainAccount: mainAccount,
            emergencyAccount: emergencyAccount,
            shares: shares,
            claimedTokens: 0
        }));
    }

    function claimTokens(uint holderIdx, uint amount) external {
        require(started, "NOT STARTED");
        ShareHolder storage shareHolder = shareHolders[holderIdx];
        require(msg.sender == shareHolder.mainAccount || msg.sender == shareHolder.emergencyAccount, "perms");
        require(amount <= claimableTokens(holderIdx), "AMOUNT");
        shareHolder.claimedTokens = shareHolder.claimedTokens.add(amount);
        IBEP20(shareholderToken).transfer(msg.sender, amount);
    }

    function unlockVestingPortion() external {
        require(unlockedPortions < totalPortions, "FULLY UNLOCKED");
        require(now > vestingTimes[unlockedPortions], "TIME");
        unlockedPortions++;
    }
}
