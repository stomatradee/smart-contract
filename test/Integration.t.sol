// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";

import {MockERC20}      from "../src/mocks/MockERC20.sol";
import {AccessRegistry} from "../src/access/AccessRegistry.sol";
import {ProjectNFT}     from "../src/core/ProjectNFT.sol";
import {Treasury}       from "../src/core/Treasury.sol";
import {LendingPool}    from "../src/core/LendingPool.sol";
import {ILendingPool}   from "../src/interfaces/ILendingPool.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DataTypes}      from "../src/libraries/DataTypes.sol";

contract IntegrationTest is Test {
    // ACTORS
    address internal admin          = makeAddr("admin");
    address internal collector      = makeAddr("collector");
    address internal investorA      = makeAddr("investorA");
    address internal investorB      = makeAddr("investorB");
    address internal investorC      = makeAddr("investorC");
    address internal platformWallet = makeAddr("platformWallet");
    address internal attacker       = makeAddr("attacker");

    // CONTRACTS
    MockERC20      internal usdc;
    AccessRegistry internal reg;
    ProjectNFT     internal nft;
    Treasury       internal treasury;
    LendingPool    internal pool;

    // PROJECT PARAMETERS
    uint256 internal constant VOLUME_KG        = 10_000;
    uint256 internal constant COLLATERAL       = 100_000_000;
    uint256 internal constant MAX_FUNDING      = 75_000_000;
    uint256 internal constant REPAY_DURATION   = 60 days;
    uint256 internal constant FUNDING_DURATION = 30 days;

    // TEST 1 — CONSTANTS
    uint256 internal constant A_INV = 20_000_000;
    uint256 internal constant B_INV = 30_000_000;
    uint256 internal constant C_INV = 25_000_000;

    uint256 internal constant BUYER_PAY_T1    = 102_000_000;
    uint256 internal constant INV_RETURN_T1   =  75_500_000;
    uint256 internal constant PLATFORM_FEE_T1 =   1_500_000;
    uint256 internal constant REMAINDER_T1    =  25_000_000;

    // Individual investor returns
    uint256 internal constant A_RETURN_T1 = 20_133_333;
    uint256 internal constant B_RETURN_T1 = 30_200_000;
    uint256 internal constant C_RETURN_T1 = 25_166_666;

    // TEST 2 — CONSTANTS
    uint256 internal constant A_INV_T2        = 30_000_000;
    uint256 internal constant BUYER_PAY_T2    = 42_000_000;
    uint256 internal constant INV_RETURN_T2   = 30_500_000;
    uint256 internal constant PLATFORM_FEE_T2 =  1_500_000;
    uint256 internal constant REMAINDER_T2    = 10_000_000;

    // TEST 3 — UNDERPAYMENT CONSTANTS
    uint256 internal constant BUYER_PAY_T5 = 50_000_000;

    uint256 internal constant A_RETURN_T5 = 13_333_333;
    uint256 internal constant B_RETURN_T5 = 20_000_000;
    uint256 internal constant C_RETURN_T5 = 16_666_666;

    // SETUP
    function setUp() public {
        usdc     = new MockERC20("Mock USDC", "USDC", 6);
        reg      = new AccessRegistry(admin);
        nft      = new ProjectNFT(admin, address(reg));
        treasury = new Treasury(admin, platformWallet);
        pool     = new LendingPool(admin, address(nft), address(treasury), address(reg), platformWallet);

        vm.startPrank(admin);
        reg.grantRole(reg.KYC_ADMIN_ROLE(), admin);
        reg.grantRole(reg.OPERATOR_ROLE(),  admin);
        reg.grantRole(reg.POOL_ROLE(),      address(nft));   // ProjectNFT calls incrementProjectCount
        reg.grantRole(reg.POOL_ROLE(),      address(pool));

        nft.grantRole(nft.KYC_ADMIN_ROLE(), admin);
        nft.grantRole(nft.POOL_ROLE(),      address(pool));

        treasury.grantRole(treasury.POOL_ROLE(), address(pool));
        pool.grantRole(pool.OPERATOR_ROLE(), admin);

        pool.setAcceptedToken(address(usdc), true);
        vm.stopPrank();

        vm.prank(collector);
        reg.registerCollector("QmCollector");

        usdc.mint(investorA, 50_000_000);
        usdc.mint(investorB, 50_000_000);
        usdc.mint(investorC, 50_000_000);
        usdc.mint(admin,    500_000_000);

        vm.prank(investorA); usdc.approve(address(pool), type(uint256).max);
        vm.prank(investorB); usdc.approve(address(pool), type(uint256).max);
        vm.prank(investorC); usdc.approve(address(pool), type(uint256).max);
        vm.prank(admin);     usdc.approve(address(pool), type(uint256).max);
    }

    // INTERNAL HELPERS
    function _mintProject() internal returns (uint256 pid) {
        vm.prank(collector);
        pid = nft.mintProject(
            address(usdc),
            "Beras",
            VOLUME_KG,
            COLLATERAL,
            FUNDING_DURATION,
            REPAY_DURATION,
            "QmIntegration"
        );
    }

    function _createAndVerify() internal returns (uint256 pid) {
        pid = _mintProject();
        vm.prank(admin);
        nft.verifyProject(pid);
    }

    function _fullFunding() internal returns (uint256 pid) {
        pid = _createAndVerify();
        vm.prank(investorA); pool.invest(pid, A_INV);
        vm.prank(investorB); pool.invest(pid, B_INV);
        vm.prank(investorC); pool.invest(pid, C_INV);
    }

    function _disburse() internal returns (uint256 pid) {
        pid = _fullFunding();
        vm.prank(admin);
        pool.disburseFunds(pid);
    }

    // TEST 1 — FULL FUNDING
    function test_T1_happyPath_fullFunding() public {
        uint256 pid = _mintProject();

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.PENDING_VERIFICATION),
            "T1: project should start as PENDING_VERIFICATION"
        );
        assertEq(nft.ownerOf(pid), collector, "T1: NFT should be owned by collector after mintProject");
        assertEq(pool.getProject(pid).maxFunding, MAX_FUNDING, "T1: maxFunding should be 75% of collateral");

        vm.prank(admin);
        nft.verifyProject(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.OPEN),
            "T1: status should be OPEN after verification"
        );
        assertTrue(pool.getProject(pid).collateralVerified, "T1: collateralVerified should be true");

        vm.prank(investorA);
        pool.invest(pid, A_INV);
        assertEq(pool.getProject(pid).totalFunded, A_INV, "T1: totalFunded after A");

        vm.prank(investorB);
        pool.invest(pid, B_INV);
        assertEq(pool.getProject(pid).totalFunded, A_INV + B_INV, "T1: totalFunded after B");

        vm.expectEmit(true, false, false, true, address(pool));
        emit ILendingPool.ProjectAutoFunded(pid, MAX_FUNDING);

        vm.prank(investorC);
        pool.invest(pid, C_INV);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.FUNDED),
            "T1: status should be FUNDED after max funding reached"
        );
        assertEq(
            treasury.projectBalances(pid, address(usdc)),
            MAX_FUNDING,
            "T1: treasury should hold exactly MAX_FUNDING"
        );

        uint256 collectorBefore = usdc.balanceOf(collector);

        vm.expectEmit(true, true, false, false, address(pool));
        emit ILendingPool.FundsDisbursed(pid, collector, MAX_FUNDING, 0);

        vm.prank(admin);
        pool.disburseFunds(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.DISBURSED),
            "T1: status should be DISBURSED"
        );
        assertEq(
            usdc.balanceOf(collector) - collectorBefore,
            MAX_FUNDING,
            "T1: collector should receive MAX_FUNDING from disbursal"
        );
        assertEq(treasury.projectBalances(pid, address(usdc)), 0, "T1: treasury balance should be zero after disbursal");

        uint256 platformBefore = usdc.balanceOf(platformWallet);

        vm.expectEmit(true, false, false, true, address(pool));
        emit ILendingPool.BuyerPaymentRecorded(pid, BUYER_PAY_T1);

        vm.prank(admin);
        pool.recordBuyerPayment(pid, BUYER_PAY_T1);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.SETTLED),
            "T1: status should be SETTLED after buyer payment"
        );
        assertEq(
            usdc.balanceOf(platformWallet) - platformBefore,
            PLATFORM_FEE_T1,
            "T1: platform should receive fee immediately on recordBuyerPayment"
        );

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.investorFunds, INV_RETURN_T1,   "T1: investorFunds correct");
        assertEq(dist.platformFee,         PLATFORM_FEE_T1, "T1: platformFee correct");
        assertEq(dist.collectorFunds,  REMAINDER_T1,    "T1: collectorFunds correct");
        assertTrue(dist.finalized, "T1: distribution should be marked done");

        assertEq(
            treasury.projectBalances(pid, address(usdc)),
            INV_RETURN_T1 + REMAINDER_T1,
            "T1: treasury should hold investorReturn + collectorFunds"
        );

        uint256 aBalBefore = usdc.balanceOf(investorA);
        vm.prank(investorA);
        pool.claimInvestorFunds(pid);
        assertApproxEqAbs(usdc.balanceOf(investorA) - aBalBefore, A_RETURN_T1, 1, "T1: investorA return should be ~20,133,333");
        assertTrue(pool.getInvestment(pid, investorA).claimed, "T1: investorA claimed flag");

        uint256 bBalBefore = usdc.balanceOf(investorB);
        vm.prank(investorB);
        pool.claimInvestorFunds(pid);
        assertEq(usdc.balanceOf(investorB) - bBalBefore, B_RETURN_T1, "T1: investorB return should be exactly 30,200,000");

        uint256 cBalBefore = usdc.balanceOf(investorC);
        vm.prank(investorC);
        pool.claimInvestorFunds(pid);
        assertApproxEqAbs(usdc.balanceOf(investorC) - cBalBefore, C_RETURN_T1, 1, "T1: investorC return should be ~25,166,666");

        uint256 collectorAfterDisbursal = usdc.balanceOf(collector);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.ProjectCompleted(pid);

        vm.prank(collector);
        pool.claimCollectorFunds(pid);

        assertEq(
            usdc.balanceOf(collector) - collectorAfterDisbursal,
            REMAINDER_T1,
            "T1: collector remainder should be 25,000,000"
        );

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.COMPLETED),
            "T1: project should be COMPLETED after all claims"
        );

        assertLe(treasury.projectBalances(pid, address(usdc)), 2, "T1: treasury dust should be at most 2 IDRX");

        assertEq(
            usdc.balanceOf(collector) - collectorBefore,
            MAX_FUNDING + REMAINDER_T1,
            "T1: collector net should be maxFunding + remainder"
        );
    }

    // TEST 2 — PARTIAL FUNDING (MANUAL CLOSE)
    function test_T2_partialFunding_manualClose() public {
        uint256 pid = _createAndVerify();

        vm.prank(investorA);
        pool.invest(pid, A_INV_T2);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.OPEN),
            "T2: should still be OPEN (not fully funded)"
        );
        assertEq(pool.getProject(pid).totalFunded, A_INV_T2, "T2: totalFunded should be 30M");

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.ProjectManuallyClosed(pid, collector, A_INV_T2);

        vm.prank(collector);
        pool.closeFunding(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.CLOSED),
            "T2: status should be CLOSED after manual close"
        );

        uint256 collectorBefore = usdc.balanceOf(collector);

        vm.prank(admin);
        pool.disburseFunds(pid);

        assertEq(
            usdc.balanceOf(collector) - collectorBefore,
            A_INV_T2,
            "T2: collector should receive exactly 30M (what was funded)"
        );
        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.DISBURSED),
            "T2: status should be DISBURSED"
        );

        // investorFunds = 30M + 10k×50 = 30,500,000
        // platformFee         = 10k×150       =  1,500,000
        // collectorFunds  = 42M − 30.5 − 1.5 = 10,000,000
        uint256 platformBefore = usdc.balanceOf(platformWallet);

        vm.prank(admin);
        pool.recordBuyerPayment(pid, BUYER_PAY_T2);

        assertEq(usdc.balanceOf(platformWallet) - platformBefore, PLATFORM_FEE_T2, "T2: platform fee should be 1.5M");

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.investorFunds, INV_RETURN_T2, "T2: investorFunds should be 30.5M");
        assertEq(dist.collectorFunds,  REMAINDER_T2,  "T2: collectorFunds should be 10M");

        vm.prank(investorA);
        pool.claimInvestorFunds(pid);

        assertTrue(pool.getInvestment(pid, investorA).claimed, "T2: investorA should be marked claimed");
        assertEq(
            usdc.balanceOf(investorA),
            50_000_000 - A_INV_T2 + INV_RETURN_T2,
            "T2: investorA final balance = 50M initial - 30M invested + 30.5M return = 50.5M"
        );

        uint256 collectorAfterDisbursal = usdc.balanceOf(collector);

        vm.prank(collector);
        pool.claimCollectorFunds(pid);

        assertEq(
            usdc.balanceOf(collector) - collectorAfterDisbursal,
            REMAINDER_T2,
            "T2: collector remainder should be 10M"
        );

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.COMPLETED),
            "T2: project should be COMPLETED"
        );
    }

    // TEST 3 — DEFAULT SCENARIO
    function test_T3_default_afterGracePeriod() public {
        uint256 pid = _disburse();

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.DISBURSED),
            "T3: should be DISBURSED before default test"
        );

        uint256 repaymentDeadline = pool.getProject(pid).repaymentDeadline;
        assertGt(repaymentDeadline, block.timestamp, "T3: repaymentDeadline should be in the future");

        vm.warp(repaymentDeadline + pool.GRACE_PERIOD() - 1);

        vm.expectRevert(abi.encodeWithSelector(
            LendingPool.LendingPool__GracePeriodNotElapsed.selector, pid, repaymentDeadline + pool.GRACE_PERIOD()
        ));
        vm.prank(admin);
        pool.markDefaulted(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.DISBURSED),
            "T3: status should still be DISBURSED (grace not elapsed)"
        );

        vm.warp(repaymentDeadline + pool.GRACE_PERIOD() + 1);

        vm.expectEmit(true, false, false, false, address(pool));
        emit ILendingPool.ProjectDefaulted(pid);

        vm.prank(admin);
        pool.markDefaulted(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.DEFAULTED),
            "T3: status should be DEFAULTED after grace period"
        );

        vm.expectRevert();
        vm.prank(investorA);
        pool.claimInvestorFunds(pid);
    }

    // TEST 4 — ACCESS CONTROL VIOLATIONS
    function test_T4_accessControl_allReverts() public {
        uint256 pid = _mintProject();

        // Attacker cannot verify, only KYC_ADMIN_ROLE on ProjectNFT
        bytes32 kycAdminRole = nft.KYC_ADMIN_ROLE();
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, kycAdminRole
        ));
        vm.prank(attacker);
        nft.verifyProject(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.PENDING_VERIFICATION),
            "T4: status should remain PENDING after unauthorized verify attempt"
        );

        vm.prank(admin);
        nft.verifyProject(pid);
        vm.prank(investorA);
        pool.invest(pid, A_INV);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NotProjectOwner.selector, pid, attacker));
        vm.prank(attacker);
        pool.closeFunding(pid);

        vm.expectRevert();
        vm.prank(investorA);
        pool.claimInvestorFunds(pid);

        vm.prank(investorB); pool.invest(pid, B_INV);
        vm.prank(investorC); pool.invest(pid, C_INV);
        vm.prank(admin); pool.disburseFunds(pid);
        vm.prank(admin); pool.recordBuyerPayment(pid, BUYER_PAY_T1);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NotInvestor.selector, pid, attacker));
        vm.prank(attacker);
        pool.claimInvestorFunds(pid);

        vm.prank(investorA);
        pool.claimInvestorFunds(pid);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__AlreadyClaimed.selector, pid, investorA));
        vm.prank(investorA);
        pool.claimInvestorFunds(pid);

        // Second project: attacker cannot disburse
        uint256 pid2 = _mintProject();
        vm.prank(admin); nft.verifyProject(pid2);
        usdc.mint(investorA, A_INV);
        vm.prank(investorA); pool.invest(pid2, A_INV);
        vm.prank(collector); pool.closeFunding(pid2);

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, pool.OPERATOR_ROLE()
        ));
        vm.prank(attacker);
        pool.disburseFunds(pid2);

        // Attacker cannot mint project, not a registered collector
        vm.expectRevert(abi.encodeWithSelector(
            ProjectNFT.ProjectNFT__NotRegisteredCollector.selector, attacker
        ));
        vm.prank(attacker);
        nft.mintProject(
            address(usdc), "Beras", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, REPAY_DURATION, "QmAttacker"
        );
    }

    // TEST 5 — BUYER UNDERPAYMENT
    function test_T5_underpayment_waterfallDistribution() public {
        uint256 pid = _disburse();

        vm.prank(admin);
        pool.recordBuyerPayment(pid, BUYER_PAY_T5);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);

        assertEq(dist.investorFunds, BUYER_PAY_T5, "T5: investorFunds should equal the buyer payment (waterfall)");
        assertEq(dist.platformFee,        0, "T5: platformFee should be 0 (underpayment)");
        assertEq(dist.collectorFunds, 0, "T5: collectorFunds should be 0 (underpayment)");
        assertTrue(dist.collectorWithdrawn, "T5: collectorWithdrawn should be auto-true when remainder = 0");

        assertEq(usdc.balanceOf(platformWallet), 0, "T5: platformWallet should receive nothing");
        assertEq(treasury.projectBalances(pid, address(usdc)), BUYER_PAY_T5, "T5: treasury should hold the underpaid amount for investors");

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NoRemainderToClaim.selector, pid));
        vm.prank(collector);
        pool.claimCollectorFunds(pid);

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.SETTLED),
            "T5: should still be SETTLED (claimCollectorFunds reverted, no state change)"
        );

        uint256 aBalBefore = usdc.balanceOf(investorA);
        vm.prank(investorA);
        pool.claimInvestorFunds(pid);
        assertApproxEqAbs(usdc.balanceOf(investorA) - aBalBefore, A_RETURN_T5, 1, "T5: investorA should receive ~13,333,333 (pro-rata of 50M)");

        uint256 bBalBefore = usdc.balanceOf(investorB);
        vm.prank(investorB);
        pool.claimInvestorFunds(pid);
        assertEq(usdc.balanceOf(investorB) - bBalBefore, B_RETURN_T5, "T5: investorB should receive exactly 20,000,000");

        uint256 cBalBefore = usdc.balanceOf(investorC);
        vm.prank(investorC);
        pool.claimInvestorFunds(pid);
        assertApproxEqAbs(usdc.balanceOf(investorC) - cBalBefore, C_RETURN_T5, 1, "T5: investorC should receive ~16,666,666 (pro-rata of 50M)");

        assertEq(
            uint8(pool.getProject(pid).status),
            uint8(DataTypes.ProjectStatus.COMPLETED),
            "T5: project should be COMPLETED (collectorWithdrawn was auto-set on zero remainder)"
        );

        assertLt(usdc.balanceOf(investorA), 50_000_000, "T5: investorA should have less than initial balance (partial recovery)");
        assertGt(usdc.balanceOf(investorA), 0,          "T5: investorA should have recovered some funds");

        assertLe(treasury.projectBalances(pid, address(usdc)), 2, "T5: treasury dust should be at most 2 IDRX");
    }

    function test_invariant_treasuryBalanceConsistency() public {
        uint256 pid = _disburse();
        vm.prank(admin);
        pool.recordBuyerPayment(pid, BUYER_PAY_T1);

        uint256 treasuryERC20Balance = usdc.balanceOf(address(treasury));
        uint256 trackedBalance       = treasury.projectBalances(pid, address(usdc));

        assertEq(treasuryERC20Balance, trackedBalance, "Invariant: treasury ERC20 balance should match tracked project balance");
    }

    function test_invariant_investmentIndexing() public {
        uint256 pid = _createAndVerify();

        vm.prank(investorA); pool.invest(pid, A_INV);
        vm.prank(investorB); pool.invest(pid, B_INV);
        vm.prank(investorC); pool.invest(pid, C_INV);

        DataTypes.Investment[] memory investments = pool.getInvestments(pid);
        assertEq(investments.length, 3, "Invariant: should have 3 investments");

        DataTypes.Investment memory a = pool.getInvestment(pid, investorA);
        assertEq(a.investor, investorA, "Invariant: investor address stored correctly");
        assertEq(a.amount,   A_INV,     "Invariant: investment amount stored correctly");
        assertFalse(a.claimed,          "Invariant: claimed flag should be false initially");

        DataTypes.Investment memory b = pool.getInvestment(pid, investorB);
        assertEq(b.amount, B_INV, "Invariant: investorB amount correct");

        DataTypes.Investment memory c = pool.getInvestment(pid, investorC);
        assertEq(c.amount, C_INV, "Invariant: investorC amount correct");
    }
}
