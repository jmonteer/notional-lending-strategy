// SPDX-License-Identifier: AGPL-3.0
pragma solidity 0.6.12;
//Problem with concise IWETH Interface used by Strategy: brownie tests require additional functions.
//IWETHoverride Interface helps to override the Strategy's IWETH interface for brownie tests through previously calling in brownie console: 
//from brownie import interface
//weth = interface.IWETHoverride("0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2")
interface IWETHoverride {
 // ERC20 Optional Views
    function name() external view returns (string memory);

    function symbol() external view returns (string memory);

    function decimals() external view returns (uint8);

    // Views
    function totalSupply() external view returns (uint);

    function balanceOf(address owner) external view returns (uint);

    function allowance(address owner, address spender) external view returns (uint);

    // Mutative functions
    function transfer(address to, uint value) external returns (bool);

    function approve(address spender, uint value) external returns (bool);

    function transferFrom(
        address from,
        address to,
        uint value
    ) external returns (bool);

    // WETH-specific functions.
    function deposit() external payable;

    function withdraw(uint amount) external;
}