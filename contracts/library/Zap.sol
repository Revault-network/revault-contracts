// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "@openzeppelin/contracts-upgradeable/access/OwnableUpgradeable.sol";
import "@pancakeswap/pancake-swap-lib/contracts/math/SafeMath.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/IBEP20.sol";
import "@pancakeswap/pancake-swap-lib/contracts/token/BEP20/SafeBEP20.sol";
import "../library/interfaces/IPancakePair.sol";
import "../library/interfaces/IPancakeFactory.sol";
import "../library/interfaces/IPancakeRouter02.sol";

contract Zap is OwnableUpgradeable {
    using SafeMath for uint;
    using SafeBEP20 for IBEP20;

    /* ========== CONSTANT VARIABLES ========== */

    address private constant CAKE = 0x0E09FaBB73Bd3Ade0a17ECC321fD13a19e81cE82;
    address private constant BUNNY = 0xC9849E6fdB743d08fAeE3E34dd2D1bc69EA11a51;
    address private constant WBNB = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c;
    address private constant BUSD = 0xe9e7CEA3DedcA5984780Bafc599bD69ADd087D56;
    address private constant USDT = 0x55d398326f99059fF775485246999027B3197955;
    address private constant DAI = 0x1AF3F329e8BE154074D8769D1FFa4eE058B1DBc3;
    address private constant USDC = 0x8AC76a51cc950d9822D68b83fE1Ad97B32Cd580d;
    address private constant VAI = 0x4BD17003473389A42DAF6a0a729f6Fdb328BbBd7;
    address private constant BTCB = 0x7130d2A12B9BCbFAe4f2634d864A1Ee1Ce3Ead9c;
    address private constant ETH = 0x2170Ed0880ac9A755fd29B2688956BD959F933F8;

    IPancakeRouter02 private constant ROUTER_V2 = IPancakeRouter02(0x10ED43C718714eb63d5aA57B78B54704E256024E);
    IPancakeFactory private constant FACTORY = IPancakeFactory(0xcA143Ce32Fe78f1f7019d7d551a6402fC5350c73);

    /* ========== STATE VARIABLES ========== */

    mapping(address => bool) private notFlip;
    mapping(address => bool) private hasApproved;
    mapping(address => address) private routePairAddresses;

    address public dustReceiver;

    event SetNotFlip(address token);
    event SetRoutePairAddress(address asset, address route);
    event SetDustReceiver(address dustReceiver);
    event TokenRemoved(uint index);

    /* ========== INITIALIZER ========== */

    function initialize(address _dustReceiver) external initializer {
        __Ownable_init();
        setNotFlip(CAKE);
        setNotFlip(BUNNY);
        setNotFlip(WBNB);
        setNotFlip(BUSD);
        setNotFlip(USDT);
        setNotFlip(DAI);
        setNotFlip(USDC);
        setNotFlip(VAI);
        setNotFlip(BTCB);
        setNotFlip(ETH);

        require(_dustReceiver != address(0), "zero address");
        dustReceiver = _dustReceiver;
    }

    receive() external payable {}

    /* ========== View Functions ========== */

    function isFlip(address _address) public view returns (bool) {
        return !notFlip[_address];
    }

    function routePair(address _address) external view returns(address) {
        return routePairAddresses[_address];
    }

    function getBUSDValue(address _token, uint _amount) external view returns (uint) {
        if (isFlip(_token)) {
            IPancakePair pair = IPancakePair(_token);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == BUSD || token1 == BUSD) {
                return IBEP20(BUSD).balanceOf(_token).mul(_amount).mul(2).div(IBEP20(_token).totalSupply());
            } else if (token0 == WBNB || token1 == WBNB) {
                uint wbnbAmount = IBEP20(WBNB).balanceOf(_token).mul(_amount).div(IBEP20(_token).totalSupply());
                address busdWbnbPair = FACTORY.getPair(BUSD, WBNB);
                return IBEP20(BUSD).balanceOf(busdWbnbPair).mul(wbnbAmount).mul(2).div(IBEP20(WBNB).balanceOf(busdWbnbPair));
            } else {
                require(false, "throw");
            }
        } else {
            if (_token == WBNB) {
                address pair = FACTORY.getPair(BUSD, WBNB);
                return IBEP20(BUSD).balanceOf(pair).mul(_amount).div(IBEP20(WBNB).balanceOf(pair));
            } else if (routePairAddresses[_token] == address(0)) {
                address pair = FACTORY.getPair(_token, WBNB);
                require(pair != address(0), "No pair");
                uint wbnbAmount = IBEP20(WBNB).balanceOf(pair).mul(_amount).div(IBEP20(_token).balanceOf(pair));
                address busdBnbPair = FACTORY.getPair(BUSD, WBNB);
                return IBEP20(BUSD).balanceOf(busdBnbPair).mul(wbnbAmount).div(IBEP20(WBNB).balanceOf(busdBnbPair));
            } else if (routePairAddresses[_token] == BUSD) {
                address pair = FACTORY.getPair(_token, BUSD);
                require(pair != address(0), "No pair");
                return IBEP20(BUSD).balanceOf(pair).mul(_amount).div(IBEP20(_token).balanceOf(pair));
            } else {
                revert("Unsupported token");
            }
        }
    }

    /* ========== External Functions ========== */

    function zapInTokenTo(address _from, uint amount, address _to, address receiver) public {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);
        if (isFlip(_from)) {
            // NOTE: We support every zap except flip <-> flip
            IPancakePair pair = IPancakePair(_from);
            address token0 = pair.token0();
            address token1 = pair.token1();
            ROUTER_V2.removeLiquidity(token0, token1, amount, 0, 0, address(this), block.timestamp);
            _approveTokenIfNeeded(token0);
            _approveTokenIfNeeded(token1);
            _swap(token0, IBEP20(token0).balanceOf(address(this)), _to, receiver);
            _swap(token1, IBEP20(token1).balanceOf(address(this)), _to, receiver);
            return;
        }

        if (isFlip(_to)) {
            IPancakePair pair = IPancakePair(_to);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (_from == token0 || _from == token1) {
                // swap half amount for other
                address other = _from == token0 ? token1 : token0;
                uint sellAmount = amount.div(2);
                uint otherAmount = _swap(_from, sellAmount, other, address(this));
                _addLiquidity(_from, other, amount.sub(sellAmount), otherAmount, receiver);
            } else {
                uint bnbAmount = _swapTokenForBNB(_from, amount, address(this));
                _swapBNBToFlip(_to, bnbAmount, receiver);
            }
        } else {
            _swap(_from, amount, _to, receiver);
        }
    }

    function zapInToken(address _from, uint amount, address _to) external {
        zapInTokenTo(_from, amount, _to, msg.sender);
    }

    function zapIn(address _to) external payable {
        _swapBNBToFlip(_to, msg.value, msg.sender);
    }

    function zapOut(address _from, uint amount) external {
        IBEP20(_from).safeTransferFrom(msg.sender, address(this), amount);
        _approveTokenIfNeeded(_from);

        if (!isFlip(_from)) {
            _swapTokenForBNB(_from, amount, msg.sender);
        } else {
            IPancakePair pair = IPancakePair(_from);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                ROUTER_V2.removeLiquidityETH(token0 != WBNB ? token0 : token1, amount, 0, 0, msg.sender, block.timestamp);
            } else {
                ROUTER_V2.removeLiquidity(token0, token1, amount, 0, 0, msg.sender, block.timestamp);
            }
        }
    }

    /* ========== Private Functions ========== */

    function _addLiquidity(
        address token0,
        address token1,
        uint amount0,
        uint amount1,
        address receiver
    ) private {
        _approveTokenIfNeeded(token0);
        _approveTokenIfNeeded(token1);
        ROUTER_V2.addLiquidity(token0, token1, amount0, amount1, 0, 0, receiver, block.timestamp);

		// Dust
        uint leftoverToken0 = IBEP20(token0).balanceOf(address(this));
        uint leftoverToken1 = IBEP20(token1).balanceOf(address(this));
        if (leftoverToken0 > 0) {
            IBEP20(token0).safeTransfer(dustReceiver, leftoverToken0);
        }
        if (leftoverToken1 > 0) {
            IBEP20(token1).safeTransfer(dustReceiver, leftoverToken1);
        }
    }

    function _addLiquidityBNB(
        address token,
        uint amountBNB,
        uint tokenAmount,
        address receiver
    ) private {
        _approveTokenIfNeeded(token);
        ROUTER_V2.addLiquidityETH{value : amountBNB }(token, tokenAmount, 0, 0, receiver, block.timestamp);

		// Dust
        uint leftoverToken = IBEP20(token).balanceOf(address(this));
        uint leftoverBNB = address(this).balance;
        if (leftoverToken > 0) {
            IBEP20(token).safeTransfer(dustReceiver, leftoverToken);
        }
        if (leftoverBNB > 0) {
            payable(dustReceiver).transfer(leftoverBNB);
        }
    }

    function _approveTokenIfNeeded(address token) private {
        if (!hasApproved[token]) {
            IBEP20(token).safeApprove(address(ROUTER_V2), uint(~0));
            hasApproved[token] = true;
        }
    }

    function _swapBNBToFlip(address flip, uint amount, address receiver) private {
        if (!isFlip(flip)) {
            _swapBNBForToken(flip, amount, receiver);
        } else {
            // flip
            IPancakePair pair = IPancakePair(flip);
            address token0 = pair.token0();
            address token1 = pair.token1();
            if (token0 == WBNB || token1 == WBNB) {
                address token = token0 == WBNB ? token1 : token0;
                uint swapValue = amount.div(2);
                uint tokenAmount = _swapBNBForToken(token, swapValue, address(this));

                _addLiquidityBNB(token, amount.sub(swapValue), tokenAmount, receiver);
            } else {
                uint swapValue = amount.div(2);
                uint token0Amount = _swapBNBForToken(token0, swapValue, address(this));
                uint token1Amount = _swapBNBForToken(token1, amount.sub(swapValue), address(this));

                _addLiquidity(token0, token1, token0Amount, token1Amount, receiver);
            }
        }
    }

    function _swapBNBForToken(address token, uint value, address receiver) private returns (uint) {
        address[] memory path;

        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = WBNB;
            path[1] = routePairAddresses[token];
            path[2] = token;
        } else {
            path = new address[](2);
            path[0] = WBNB;
            path[1] = token;
        }
        uint[] memory amounts = ROUTER_V2.swapExactETHForTokens{value : value}(0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swapTokenForBNB(address token, uint amount, address receiver) private returns (uint) {
        address[] memory path;
        if (routePairAddresses[token] != address(0)) {
            path = new address[](3);
            path[0] = token;
            path[1] = routePairAddresses[token];
            path[2] = WBNB;
        } else {
            path = new address[](2);
            path[0] = token;
            path[1] = WBNB;
        }

        uint[] memory amounts = ROUTER_V2.swapExactTokensForETH(amount, 0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    function _swap(address _from, uint amount, address _to, address receiver) private returns (uint) {
        address intermediate = routePairAddresses[_from];
        if (intermediate == address(0)) {
            intermediate = routePairAddresses[_to];
        }

        address[] memory path;
        if (intermediate != address(0) && (_from == WBNB || _to == WBNB)) {
            // [WBNB, BUSD, VAI] or [VAI, BUSD, WBNB]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (intermediate != address(0) && (_from == intermediate || _to == intermediate)) {
            // [VAI, BUSD] or [BUSD, VAI]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] == routePairAddresses[_to]) {
            // [VAI, DAI] or [VAI, USDC]
            path = new address[](3);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = _to;
        } else if (routePairAddresses[_from] != address(0) && routePairAddresses[_to] != address(0) && routePairAddresses[_from] != routePairAddresses[_to]) {
            // routePairAddresses[xToken] = xRoute
            // [VAI, BUSD, WBNB, xRoute, xToken]
            path = new address[](5);
            path[0] = _from;
            path[1] = routePairAddresses[_from];
            path[2] = WBNB;
            path[3] = routePairAddresses[_to];
            path[4] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_from] != address(0)) {
            // [VAI, BUSD, WBNB, BUNNY]
            path = new address[](4);
            path[0] = _from;
            path[1] = intermediate;
            path[2] = WBNB;
            path[3] = _to;
        } else if (intermediate != address(0) && routePairAddresses[_to] != address(0)) {
            // [BUNNY, WBNB, BUSD, VAI]
            path = new address[](4);
            path[0] = _from;
            path[1] = WBNB;
            path[2] = intermediate;
            path[3] = _to;
        } else if (_from == WBNB || _to == WBNB) {
            // [WBNB, BUNNY] or [BUNNY, WBNB]
            path = new address[](2);
            path[0] = _from;
            path[1] = _to;
        } else {
            // [USDT, BUNNY] or [BUNNY, USDT]
            path = new address[](3);
            path[0] = _from;
            path[1] = WBNB;
            path[2] = _to;
        }

        uint[] memory amounts = ROUTER_V2.swapExactTokensForTokens(amount, 0, path, receiver, block.timestamp);
        return amounts[amounts.length - 1];
    }

    /* ========== RESTRICTED FUNCTIONS ========== */

    function setRoutePairAddress(address asset, address route) external onlyOwner {
        routePairAddresses[asset] = route;
        emit SetRoutePairAddress(asset, route);
    }

    function setNotFlip(address token) public onlyOwner {
        notFlip[token] = true;
        emit SetNotFlip(token);
    }

    function setDustReceiver(address _dustReceiver) external onlyOwner {
        require(_dustReceiver != address(0), "zero address");
        dustReceiver = _dustReceiver;
        emit SetDustReceiver(_dustReceiver);
    }
}
