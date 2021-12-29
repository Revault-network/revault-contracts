// SPDX-License-Identifier: MIT
pragma solidity 0.6.12;

interface IRevaChef {
    function notifyDeposited(address user, address token, uint amount) external;
    function notifyWithdrawn(address user, address token, uint amount) external;
    function claim(address token) external;
    function claimFor(address token, address to) external;
}
