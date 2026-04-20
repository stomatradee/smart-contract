pragma solidity 0.8.24;

import {Script, console2} from "forge-std/Script.sol";

import {MockERC20}       from "../src/mocks/MockERC20.sol";
import {AccessRegistry}  from "../src/access/AccessRegistry.sol";
import {ProjectNFT}      from "../src/core/ProjectNFT.sol";
import {Treasury}        from "../src/core/Treasury.sol";
import {LendingPool}     from "../src/core/LendingPool.sol";
import {SwapFacilitator} from "../src/periphery/SwapFacilitator.sol";

contract Deploy is Script {
    uint256 private constant ARBITRUM_ONE_CHAIN_ID = 42_161;

    address private constant USDC_MAINNET = 0xaf88d065e77c8cC2239327C5EDb3A432268e5831;
    address private constant USDT_MAINNET = 0xFd086bC7CD5C481DCC9C85ebE478A1C0b69FCbb9;

    struct Deployed {
        address usdc;
        address usdt;
        address accessRegistry;
        address projectNft;
        address treasury;
        address lendingPool;
        address swapFacilitator;
    }

    function run() external {
        uint256 deployerKey    = vm.envUint("PRIVATE_KEY");
        address deployer       = vm.addr(deployerKey);
        address platformWallet = vm.envOr("PLATFORM_WALLET", deployer);
        bool    isMainnet      = block.chainid == ARBITRUM_ONE_CHAIN_ID;

        _printHeader(deployer, platformWallet, isMainnet);

        vm.startBroadcast(deployerKey);

        Deployed memory d;

        if (isMainnet) {
            d.usdc = vm.envOr("USDC_ADDRESS", USDC_MAINNET);
            d.usdt = vm.envOr("USDT_ADDRESS", USDT_MAINNET);
            console2.log("\n--- Phase 1: Tokens (mainnet) ---");
            console2.log("  USDC :", d.usdc);
            console2.log("  USDT :", d.usdt);
        } else {
            d = _phase1MockTokens(d);
        }

        d = _phase2CoreContracts(d, deployer, platformWallet);
        d = _phase3Configure(d, deployer);
        d = _phase4Swap(d);

        if (!isMainnet) {
            _phase5TestData(d, deployer);
        } else {
            console2.log("\n--- Phase 5: Test Data --- [SKIPPED on mainnet]");
        }

        vm.stopBroadcast();
        _printSummary(d, isMainnet);
    }

    function _phase1MockTokens(Deployed memory d) internal returns (Deployed memory) {
        console2.log("\n--- Phase 1: Mock Tokens (testnet) ---");

        MockERC20 usdc = new MockERC20("Mock USDC", "USDC", 6);
        console2.log("  [+] MockUSDC :", address(usdc));
        d.usdc = address(usdc);

        MockERC20 usdt = new MockERC20("Mock USDT", "USDT", 6);
        console2.log("  [+] MockUSDT :", address(usdt));
        d.usdt = address(usdt);

        return d;
    }

    function _phase2CoreContracts(
        Deployed memory d,
        address deployer,
        address platformWallet
    ) internal returns (Deployed memory) {
        console2.log("\n--- Phase 2: Core Contracts ---");

        AccessRegistry accessRegistry = new AccessRegistry(deployer);
        console2.log("  [+] AccessRegistry :", address(accessRegistry));
        d.accessRegistry = address(accessRegistry);

        ProjectNFT projectNft = new ProjectNFT(deployer, address(accessRegistry));
        console2.log("  [+] ProjectNFT     :", address(projectNft));
        d.projectNft = address(projectNft);

        Treasury treasury = new Treasury(deployer, platformWallet);
        console2.log("  [+] Treasury       :", address(treasury));
        d.treasury = address(treasury);

        LendingPool lendingPool = new LendingPool(
            deployer, address(projectNft), address(treasury), address(accessRegistry), platformWallet
        );
        console2.log("  [+] LendingPool    :", address(lendingPool));
        d.lendingPool = address(lendingPool);

        return d;
    }

    function _phase3Configure(
        Deployed memory d,
        address deployer
    ) internal returns (Deployed memory) {
        console2.log("\n--- Phase 3: Configuration ---");

        AccessRegistry accessRegistry = AccessRegistry(d.accessRegistry);
        ProjectNFT     projectNft     = ProjectNFT(d.projectNft);
        Treasury       treasury       = Treasury(d.treasury);
        LendingPool    lendingPool    = LendingPool(d.lendingPool);

        accessRegistry.grantRole(accessRegistry.KYC_ADMIN_ROLE(), deployer);
        console2.log("  [OK] AccessRegistry.KYC_ADMIN_ROLE  > deployer");

        accessRegistry.grantRole(accessRegistry.POOL_ROLE(), d.lendingPool);
        console2.log("  [OK] AccessRegistry.POOL_ROLE       > LendingPool");

        accessRegistry.grantRole(accessRegistry.POOL_ROLE(), d.projectNft);
        console2.log("  [OK] AccessRegistry.POOL_ROLE       > ProjectNFT");

        projectNft.grantRole(projectNft.KYC_ADMIN_ROLE(), deployer);
        console2.log("  [OK] ProjectNFT.KYC_ADMIN_ROLE      > deployer");

        projectNft.grantRole(projectNft.POOL_ROLE(), d.lendingPool);
        console2.log("  [OK] ProjectNFT.POOL_ROLE           > LendingPool");

        treasury.grantRole(treasury.POOL_ROLE(), d.lendingPool);
        console2.log("  [OK] Treasury.POOL_ROLE             > LendingPool");

        lendingPool.grantRole(lendingPool.OPERATOR_ROLE(), deployer);
        console2.log("  [OK] LendingPool.OPERATOR_ROLE      > deployer");

        lendingPool.setAcceptedToken(d.usdc, true);
        lendingPool.setAcceptedToken(d.usdt, true);
        console2.log("  [OK] Accepted tokens: USDC, USDT");

        return d;
    }

    function _phase4Swap(Deployed memory d) internal returns (Deployed memory) {
        address router = vm.envOr("CAMELOT_ROUTER", address(0));
        address weth   = vm.envOr("WETH_ADDRESS",   address(0));

        if (router == address(0) || weth == address(0)) {
            console2.log("\n--- Phase 4: SwapFacilitator --- [SKIPPED]");
            console2.log("  Set CAMELOT_ROUTER + WETH_ADDRESS, or run: forge script script/DeploySwap.s.sol");
            return d;
        }

        console2.log("\n--- Phase 4: SwapFacilitator ---");
        SwapFacilitator sf = new SwapFacilitator(router, weth, d.usdc, d.usdt);
        console2.log("  [+] SwapFacilitator :", address(sf));
        d.swapFacilitator = address(sf);

        return d;
    }

    function _phase5TestData(Deployed memory d, address deployer) internal {
        console2.log("\n--- Phase 5: Test Data (testnet) ---");

        MockERC20 usdc = MockERC20(d.usdc);
        MockERC20 usdt = MockERC20(d.usdt);

        // Mint tokens ke deployer untuk testing nanti
        usdc.mint(deployer, 10_000_000 * 1e6);
        usdt.mint(deployer, 10_000_000 * 1e6);
        console2.log("  [+] Minted 10M USDC + 10M USDT to deployer");

        // Mint ke investor test (jika ada)
        address inv1 = vm.envOr("INVESTOR_1", address(0));
        address inv2 = vm.envOr("INVESTOR_2", address(0));
        address inv3 = vm.envOr("INVESTOR_3", address(0));

        if (inv1 != address(0)) { usdc.mint(inv1, 1_000_000 * 1e6); console2.log("  [+] 1M USDC to INVESTOR_1:", inv1); }
        if (inv2 != address(0)) { usdc.mint(inv2, 1_000_000 * 1e6); console2.log("  [+] 1M USDC to INVESTOR_2:", inv2); }
        if (inv3 != address(0)) { usdc.mint(inv3, 1_000_000 * 1e6); console2.log("  [+] 1M USDC to INVESTOR_3:", inv3); }

        // Register deployer sebagai collector (supaya bisa mint project nanti)
        AccessRegistry(d.accessRegistry).registerCollector("QmDeployerProfile");
        console2.log("  [+] Registered deployer as collector");

        // Approve Treasury untuk spending (perlu untuk invest nanti)
        usdc.approve(address(Treasury(d.treasury)), type(uint256).max);
        usdt.approve(address(Treasury(d.treasury)), type(uint256).max);
        console2.log("  [+] Approved Treasury for USDC + USDT");

        console2.log("  [i] No sample projects created. Mint manually via frontend or cast.");
    }

    function _printHeader(address deployer, address platformWallet, bool isMainnet) internal view {
        console2.log("==============================================");
        console2.log("  StomaTrace Deploy Script");
        console2.log("==============================================");
        console2.log("  Deployer        :", deployer);
        console2.log("  Platform Wallet :", platformWallet);
        console2.log("  Chain ID        :", block.chainid);
        console2.log("  Network         :", isMainnet ? "Arbitrum One (MAINNET)" : "Testnet/Local");
        console2.log("==============================================");
    }

    function _printSummary(Deployed memory d, bool isMainnet) internal view {
        console2.log("\n=== DEPLOYED ADDRESSES ===");
        console2.log("Network         :", block.chainid);
        console2.log("--- Tokens ---");
        if (!isMainnet) {
            console2.log("MockUSDC        :", d.usdc);
            console2.log("MockUSDT        :", d.usdt);
        } else {
            console2.log("USDC (real)     :", d.usdc);
            console2.log("USDT (real)     :", d.usdt);
        }
        console2.log("--- Core Contracts ---");
        console2.log("AccessRegistry  :", d.accessRegistry);
        console2.log("ProjectNFT      :", d.projectNft);
        console2.log("Treasury        :", d.treasury);
        console2.log("LendingPool     :", d.lendingPool);
        if (d.swapFacilitator != address(0)) {
            console2.log("SwapFacilitator :", d.swapFacilitator);
        } else {
            console2.log("SwapFacilitator : NOT DEPLOYED (run DeploySwap.s.sol)");
        }

        console2.log("\n=== .env FORMAT ===");
        console2.log(string.concat("NEXT_PUBLIC_CHAIN_ID=",         vm.toString(block.chainid)));
        console2.log(string.concat("NEXT_PUBLIC_USDC_ADDRESS=",     vm.toString(d.usdc)));
        console2.log(string.concat("NEXT_PUBLIC_USDT_ADDRESS=",     vm.toString(d.usdt)));
        console2.log(string.concat("NEXT_PUBLIC_ACCESS_REGISTRY=",  vm.toString(d.accessRegistry)));
        console2.log(string.concat("NEXT_PUBLIC_PROJECT_NFT=",      vm.toString(d.projectNft)));
        console2.log(string.concat("NEXT_PUBLIC_TREASURY=",         vm.toString(d.treasury)));
        console2.log(string.concat("NEXT_PUBLIC_LENDING_POOL=",     vm.toString(d.lendingPool)));
        if (d.swapFacilitator != address(0)) {
            console2.log(string.concat("NEXT_PUBLIC_SWAP_FACILITATOR=", vm.toString(d.swapFacilitator)));
        }

        console2.log("\n=== NEXT STEPS ===");
        console2.log("1. Verify on Arbiscan: forge script script/Deploy.s.sol --verify --rpc-url $RPC");
        if (d.swapFacilitator == address(0)) {
            console2.log("2. Deploy SwapFacilitator: forge script script/DeploySwap.s.sol --broadcast --verify");
        }
        if (isMainnet) {
            console2.log("3. Transfer DEFAULT_ADMIN_ROLE to multisig");
            console2.log("4. Revoke deployer operational roles");
        }
    }
}
