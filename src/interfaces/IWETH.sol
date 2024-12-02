// IWETH.sol
pragma solidity ^0.8.0;

interface IWETH {
    function deposit() external payable; // Convert ETH to WETH
    function withdraw(uint256 amount) external; // Convert WETH to ETH
}
