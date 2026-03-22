pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";
import {SwapFacilitator}  from "../src/periphery/SwapFacilitator.sol";

contract DeploySwap is Script {
    function run() external {
        uint256 deployerKey = vm.envUint("PRIVATE_KEY");
        address deployer    = vm.addr(deployerKey);
        address router      = vm.envAddress("CAMELOT_ROUTER");
        address weth        = vm.envAddress("WETH_ADDRESS");
        address usdc        = vm.envAddress("USDC_ADDRESS");
        address usdt        = vm.envAddress("USDT_ADDRESS");
        address lendingPool = vm.envOr("LENDING_POOL_ADDRESS", address(0));

        require(router != address(0), "DeploySwap: CAMELOT_ROUTER not set");
        require(weth   != address(0), "DeploySwap: WETH_ADDRESS not set");
        require(usdc   != address(0), "DeploySwap: USDC_ADDRESS not set");
        require(usdt   != address(0), "DeploySwap: USDT_ADDRESS not set");

        console2.log("==============================================");
        console2.log("  StomaTrace - DeploySwap (Camelot V2)");
        console2.log("==============================================");
        console2.log("  Deployer       :", deployer);
        console2.log("  Camelot Router :", router);
        console2.log("  WETH           :", weth);
        console2.log("  USDC           :", usdc);
        console2.log("  USDT           :", usdt);
        console2.log("  Chain ID       :", block.chainid);
        console2.log("==============================================");

        vm.startBroadcast(deployerKey);
        SwapFacilitator facilitator = new SwapFacilitator(router, weth, usdc, usdt);
        vm.stopBroadcast();

        console2.log("\n=== DEPLOYMENT SUMMARY ===");
        console2.log("  SwapFacilitator :", address(facilitator));
        console2.log("  Owner           :", deployer);
        if (lendingPool != address(0)) {
            console2.log("  LendingPool     :", lendingPool);
        }
        console2.log("\n  Next steps:");
        console2.log("    1. Verify: forge script script/DeploySwap.s.sol --verify");
        console2.log("    2. Update frontend with SwapFacilitator address");
        console2.log("    3. (Production) facilitator.transferOwnership(multisig)");
    }
}
