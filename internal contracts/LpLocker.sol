//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";

contract LpLocker {

    address public lpToken;
    address public recipient;
    uint public releaseTime;
    address public timelockContract;

    constructor(
        address _lpToken,
        address _recipient,
        uint _releaseTime,
        address _timelockContract
    ) public {
        lpToken = _lpToken;
        recipient = _recipient;
        releaseTime = _releaseTime;
        timelockContract = _timelockContract;
    }

    function claimLpTokens() external {
        require(msg.sender == recipient, "RECIPIENT ONLY");
        require(now >= releaseTime, "STILL LOCKED");
        uint balance = IBEP20(lpToken).balanceOf(address(this));
        IBEP20(lpToken).transfer(recipient, balance);
    }

    // In case of pancakeswap migration, emergency withdraw behind timelock
    function emergencyWithdraw() external {
        require(msg.sender == timelockContract, "TIMELOCK ONLY");
        uint balance = IBEP20(lpToken).balanceOf(address(this));
        IBEP20(lpToken).transfer(recipient, balance);
    }
}
