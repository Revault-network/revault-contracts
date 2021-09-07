// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;


import "../library/BEP20.sol";

// RevaToken with Governance.
contract RevaToken is BEP20('Reva Token', 'REVA') {

    uint public constant FEE_PRECISION = 1000000;
    uint public constant MAX_FEE = 10000;
    address private constant DEAD = 0x000000000000000000000000000000000000dEaD;

    address public treasury;
    address public revaStakeFeeReceiver;
    address public revaLpStakeFeeReceiver;
    uint public burnFee;
    uint public treasuryFee;
    uint public revaStakeFee;
    uint public revaLpStakeFee;

    mapping (address => bool) public isMinter;

    uint public constant MAX_SUPPLY = 18181818 * 1e18;

    event NewTreasury(address treasury, uint treasuryFee);
    event NewRevaStakeFeeReceiver(address revaStakeFeeReceiver, uint revaStakeFee);
    event NewRevaLpStakeFeeReceiver(address revaLpStakeFeeReceiver, uint revaLpStakeFee);
    event NewBurnFee(uint burnFee);
    event NewMinter(address minter, bool enabled);

    // @dev Creates `_amount` token to `_to`. Must only be called by the owner (MasterChef).
    function mint(address _to, uint256 _amount) external {
        require(totalSupply().add(_amount) <= MAX_SUPPLY, "MAX_SUPPLY");
        require(isMinter[msg.sender], "not minter");
        _mint(_to, _amount);
    }

    function setTreasury(address _treasury, uint _treasuryFee) external onlyOwner {
        require(_treasury != address(0), "Not zero address");
        require(_treasuryFee <= MAX_FEE, "MAX_FEE");
        treasury = _treasury;
        treasuryFee = _treasuryFee;
        emit NewTreasury(_treasury, _treasuryFee);
    }

    function setRevaStakeFeeReceiver(address _revaStakeFeeReceiver, uint _revaStakeFee) external onlyOwner {
        require(_revaStakeFeeReceiver != address(0), "Not zero address");
        require(_revaStakeFee <= MAX_FEE, "MAX_FEE");
        revaStakeFeeReceiver = _revaStakeFeeReceiver;
        revaStakeFee = _revaStakeFee;
        emit NewRevaStakeFeeReceiver(_revaStakeFeeReceiver, _revaStakeFee);
    }

    function setRevaLpStakeFeeReceiver(address _revaLpStakeFeeReceiver, uint _revaLpStakeFee) external onlyOwner {
        require(_revaLpStakeFeeReceiver != address(0), "Not zero address");
        require(_revaLpStakeFee <= MAX_FEE, "MAX_FEE");
        revaLpStakeFeeReceiver = _revaLpStakeFeeReceiver;
        revaLpStakeFee = _revaLpStakeFee;
        emit NewRevaLpStakeFeeReceiver(_revaLpStakeFeeReceiver, _revaLpStakeFee);
    }

    function setBurnFee(uint _burnFee) external onlyOwner {
        require(_burnFee <= MAX_FEE, "MAX_FEE");
        burnFee = _burnFee;
        emit NewBurnFee(_burnFee);
    }

    function setMinter(address _minter, bool _enabled) external onlyOwner {
        isMinter[_minter] = _enabled;
        emit NewMinter(_minter, _enabled);
    }

    //@dev See {BEP20-transfer}.
    function transfer(address recipient, uint256 amount) public override returns (bool) {
        uint256 transferBurnFee = amount.mul(burnFee).div(FEE_PRECISION);
        uint256 transferTreasuryFee = amount.mul(treasuryFee).div(FEE_PRECISION);
        uint256 transferRevaStakeFee = amount.mul(revaStakeFee).div(FEE_PRECISION);
        uint256 transferRevaLpStakeFee = amount.mul(revaLpStakeFee).div(FEE_PRECISION);
        uint256 totalFees = transferBurnFee.add(transferTreasuryFee).add(transferRevaStakeFee).add(transferRevaLpStakeFee);
        uint256 finalAmount = amount.sub(totalFees);
        _transfer(_msgSender(), DEAD, transferBurnFee);
        _transfer(_msgSender(), treasury, transferTreasuryFee);
        _transfer(_msgSender(), revaStakeFeeReceiver, transferRevaStakeFee);
        _transfer(_msgSender(), revaLpStakeFeeReceiver, transferRevaLpStakeFee);
        _transfer(_msgSender(), recipient, finalAmount);
        return true;
    }

    function transferFrom(
        address sender,
        address recipient,
        uint256 amount
    ) public override returns (bool) {
        {
            uint256 transferBurnFee = amount.mul(burnFee).div(FEE_PRECISION);
            uint256 transferTreasuryFee = amount.mul(treasuryFee).div(FEE_PRECISION);
            uint256 transferRevaStakeFee = amount.mul(revaStakeFee).div(FEE_PRECISION);
            uint256 transferRevaLpStakeFee = amount.mul(revaLpStakeFee).div(FEE_PRECISION);
            uint256 totalFees = transferBurnFee.add(transferTreasuryFee).add(transferRevaStakeFee).add(transferRevaLpStakeFee);
            uint256 finalAmount = amount.sub(totalFees);
            _transfer(sender, DEAD, transferBurnFee);
            _transfer(sender, treasury, transferTreasuryFee);
            _transfer(sender, revaStakeFeeReceiver, transferRevaStakeFee);
            _transfer(sender, revaLpStakeFeeReceiver, transferRevaLpStakeFee);
            _transfer(sender, recipient, finalAmount);
        }
        _approve(
            sender,
            _msgSender(),
            _allowances[sender][_msgSender()].sub(amount, 'BEP20: transfer amount exceeds allowance')
        );
        return true;
    }

}
