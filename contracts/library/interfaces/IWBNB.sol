// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;

// vault that controls a single token
interface IWBNB {
    function withdraw(uint wad) external;
    function deposit() external payable;
    function transferFrom(address from, address to, uint amount) external returns (bool);
}
