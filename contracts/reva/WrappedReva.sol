// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

import "../library/BEP20.sol";

// RevaToken with Governance.
contract WrappedReva is BEP20('Wrapped Reva Token', 'WREVA') {

    IBEP20 public constant revaToken = IBEP20(0x4FdD92Bd67Acf0676bfc45ab7168b3996F7B4A3B);

    event  Deposit(address indexed account, uint amount, uint receivedAmount);
    event  Withdrawal(address indexed account, uint amount);
    event  WithdrawalTo(address indexed from, address indexed to, uint amount);

    function withdraw(uint amount) external {
        _burn(msg.sender, amount);
        revaToken.transfer(msg.sender, amount);
        emit Withdrawal(msg.sender, amount);
    }

    function withdrawTo(uint amount, address receiver) external {
        _burn(msg.sender, amount);
        revaToken.transfer(receiver, amount);
        emit WithdrawalTo(msg.sender, receiver, amount);
    }

    function deposit(uint amount) external {
        uint prevBalance = revaToken.balanceOf(address(this));
        revaToken.transferFrom(msg.sender, address(this), amount);
        uint postBalance = revaToken.balanceOf(address(this));
        uint received = postBalance.sub(prevBalance);
        _mint(msg.sender, received);
        emit Deposit(msg.sender, amount, received);
    }
}
