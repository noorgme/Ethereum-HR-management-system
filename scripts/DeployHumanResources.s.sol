// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.17;

import {Script} from "../lib/forge-std/src/Script.sol";
import {HumanResources} from "../src/HumanResources.sol";

contract DeployHumanResourcesScript is Script {
    function run() external {
        // Constructor arguments
        address usdc = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;           // USDC token address
        address weth = 0x4200000000000000000000000000000000000006;           // WETH token address
        address usdcEthOracle = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;  // Chainlink USDC/ETH price oracle
        address uniswapRouter = 0xE592427A0AEce92De3Edee1F18E0157C05861564;  // Uniswap router address

        vm.startBroadcast();
        new HumanResources(usdc, weth, usdcEthOracle, uniswapRouter);
        vm.stopBroadcast();
    }
}
