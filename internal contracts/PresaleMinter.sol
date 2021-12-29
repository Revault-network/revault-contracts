//SPDX-License-Identifier: Unlicense
pragma solidity ^0.6.12;

import "@pancakeswap/pancake-swap-lib/contracts/access/Ownable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";

contract PresaleMinter is Ownable {
    using SafeMath for uint;

    address public presaleToken;
    address public revaToken;

    uint public constant MULTIPLIER = 120480776608;
    uint public constant MULTIPLIER_PRECISION = 100000000000;

    mapping (address => bool) public hasReceivedTokens;

    constructor(address _presaleToken, address _revaToken) public {
        presaleToken = _presaleToken;
        revaToken = _revaToken;
    }

    function mint(address receiver) external onlyOwner {
        require(!hasReceivedTokens[receiver]);
        hasReceivedTokens[receiver] = true;
        uint presaleAmount = IBEP20(presaleToken).balanceOf(receiver);
        uint amount = presaleAmount.mul(MULTIPLIER).div(MULTIPLIER_PRECISION);
        IRevaToken(revaToken).mint(receiver, amount);
    }
}

interface IRevaToken {
    function mint(address _to, uint256 _amount) external;
}
