// SPDX-License-Identifier: MIT
pragma solidity ^0.6.12;


abstract contract IZap {
    function getBUSDValue(address _token, uint _amount) external view virtual returns (uint);
    function zapInTokenTo(address _from, uint amount, address _to, address receiver) public virtual;
    function zapInToken(address _from, uint amount, address _to) external virtual;
    function zapInTo(address _to, address _receiver) external virtual payable;
    function zapIn(address _to) external virtual payable;
    function zapInTokenToBNB(address _from, uint amount) external virtual;
}