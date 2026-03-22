// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingPool}    from "../src/core/LendingPool.sol";
import {ProjectNFT}     from "../src/core/ProjectNFT.sol";
import {Treasury}       from "../src/core/Treasury.sol";
import {AccessRegistry} from "../src/access/AccessRegistry.sol";
import {ILendingPool}   from "../src/interfaces/ILendingPool.sol";
import {IProjectNFT}    from "../src/interfaces/IProjectNFT.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";
import {DataTypes}      from "../src/libraries/DataTypes.sol";


contract MockToken {
    string public name;
    string public symbol;
    uint8  public decimals;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol, uint8 _decimals) {
        name     = _name;
        symbol   = _symbol;
        decimals = _decimals;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;
        emit Transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
        return true;
    }
}


contract LendingPoolTest is Test {
    // ACTORS
    address internal admin          = makeAddr("admin");
    address internal operator       = makeAddr("operator");
    address internal kycAdmin       = makeAddr("kycAdmin");
    address internal platformWallet = makeAddr("platformWallet");
    address internal collector      = makeAddr("collector");
    address internal inv1           = makeAddr("inv1");
    address internal inv2           = makeAddr("inv2");
    address internal inv3           = makeAddr("inv3");
    address internal attacker       = makeAddr("attacker");

    // CONTRACTS
    LendingPool    internal pool;
    ProjectNFT     internal nft;
    Treasury       internal treasury;
    AccessRegistry internal accessReg;
    MockToken      internal usdc;

    // CONSTANTS
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant POOL_ROLE          = keccak256("POOL_ROLE");
    bytes32 internal constant KYC_ADMIN_ROLE     = keccak256("KYC_ADMIN_ROLE");
    bytes32 internal constant OPERATOR_ROLE      = keccak256("OPERATOR_ROLE");

    uint256 internal constant COLLATERAL      = 2_000e6;
    uint256 internal constant MAX_FUNDING     = 1_500e6;
    uint256 internal constant VOLUME_KG       = 1_000_000;
 
    uint256 internal constant INVESTOR_RETURN = 1_550e6;
    uint256 internal constant PLATFORM_FEE    = 150e6;
    uint256 internal constant FULL_REQUIRED   = 1_700e6;
    uint256 internal constant BUYER_OVERPAYS  = 1_850e6; // remainder = 150e6

    uint256 internal constant FUNDING_DURATION   = 1 days;
    uint256 internal constant REPAYMENT_DURATION = 30 days;

    // SETUP
    function setUp() public {
        accessReg = new AccessRegistry(admin);
        treasury  = new Treasury(admin, platformWallet);
        nft       = new ProjectNFT(admin, address(accessReg));
        pool      = new LendingPool(
            admin,
            address(nft),
            address(treasury),
            address(accessReg),
            platformWallet
        );
        usdc = new MockToken("USD Coin", "USDC", 6);

        vm.startPrank(admin);
        accessReg.grantRole(KYC_ADMIN_ROLE, kycAdmin);
        accessReg.grantRole(POOL_ROLE,      address(pool));
        accessReg.grantRole(POOL_ROLE,      address(nft));
        nft.grantRole(KYC_ADMIN_ROLE,       kycAdmin);
        nft.grantRole(POOL_ROLE,            address(pool));
        treasury.grantRole(POOL_ROLE,       address(pool));
        pool.grantRole(OPERATOR_ROLE,       operator);
        pool.setAcceptedToken(address(usdc), true);
        vm.stopPrank();

        vm.prank(collector);
        accessReg.registerCollector("QmCollector");

        usdc.mint(inv1,     MAX_FUNDING);
        usdc.mint(inv2,     MAX_FUNDING);
        usdc.mint(inv3,     MAX_FUNDING);
        usdc.mint(operator, BUYER_OVERPAYS + 1_000e6);

        vm.prank(inv1);     usdc.approve(address(pool), type(uint256).max);
        vm.prank(inv2);     usdc.approve(address(pool), type(uint256).max);
        vm.prank(inv3);     usdc.approve(address(pool), type(uint256).max);
        vm.prank(operator); usdc.approve(address(pool), type(uint256).max);
    }

    function _mintProject() internal returns (uint256 pid) {
        vm.prank(collector);
        pid = nft.mintProject(
            address(usdc), "Kopi Robusta", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function _createVerifiedProject() internal returns (uint256 pid) {
        pid = _mintProject();
        vm.prank(kycAdmin);
        nft.verifyProject(pid);
    }

    function _fundedProject() internal returns (uint256 pid) {
        pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 500e6);
        vm.prank(inv2); pool.invest(pid, 500e6);
        vm.prank(inv3); pool.invest(pid, 500e6);
    }

    function _disbursedProject() internal returns (uint256 pid) {
        pid = _fundedProject();
        vm.prank(operator);
        pool.disburseFunds(pid);
    }

    function _settledProject() internal returns (uint256 pid) {
        pid = _disbursedProject();
        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);
    }

    // 1. DEPLOYMENT
    function test_deployment_adminHasRole() public view {
        assertTrue(pool.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_deployment_operatorRoleAssigned() public view {
        assertTrue(pool.hasRole(OPERATOR_ROLE, operator));
    }

    function test_deployment_externalDepsWired() public view {
        assertEq(address(pool.projectNft()),     address(nft));
        assertEq(address(pool.treasury()),       address(treasury));
        assertEq(address(pool.accessRegistry()), address(accessReg));
        assertEq(pool.platformWallet(),          platformWallet);
    }

    function test_deployment_revertOnAnyZeroAddress() public {
        vm.expectRevert(LendingPool.LendingPool__ZeroAddress.selector);
        new LendingPool(address(0), address(nft), address(treasury), address(accessReg), platformWallet);

        vm.expectRevert(LendingPool.LendingPool__ZeroAddress.selector);
        new LendingPool(admin, address(0), address(treasury), address(accessReg), platformWallet);

        vm.expectRevert(LendingPool.LendingPool__ZeroAddress.selector);
        new LendingPool(admin, address(nft), address(0), address(accessReg), platformWallet);
    }

    function test_deployment_tokenWhitelistCorrect() public view {
        assertTrue(pool.acceptedTokens(address(usdc)));
    }

    // 2. MINT PROJECT
    function test_mintProject_succeeds() public {
        uint256 pid = _mintProject();

        assertEq(pid, 1);
        assertEq(pool.projectCount(), 1);
    }

    function test_mintProject_storesCorrectData() public {
        uint256 pid = _mintProject();

        DataTypes.Project memory p = pool.getProject(pid);
        assertEq(p.collector,       collector);
        assertEq(p.acceptedToken,   address(usdc));
        assertEq(p.volumeKg,        VOLUME_KG);
        assertEq(p.collateralValue, COLLATERAL);
        assertEq(p.maxFunding,      MAX_FUNDING);
        assertEq(p.totalFunded,     0);
        assertEq(uint8(p.status),   uint8(DataTypes.ProjectStatus.PENDING_VERIFICATION));
        assertFalse(p.collateralVerified);
    }

    function test_mintProject_mintsNFTToCollector() public {
        uint256 pid = _mintProject();
        assertEq(nft.ownerOf(pid), collector);
    }

    function test_mintProject_emitsProjectMinted() public {
        vm.expectEmit(true, true, true, false, address(nft));
        emit IProjectNFT.ProjectMinted(1, collector, address(usdc), VOLUME_KG, MAX_FUNDING);

        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Kopi Robusta", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function test_mintProject_computesMaxFundingCorrectly() public {
        uint256 pid = _mintProject();
        assertEq(pool.getProject(pid).maxFunding, (COLLATERAL * 7500) / 10_000);
    }

    function test_mintProject_revertWhenCollectorNotRegistered() public {
        vm.expectRevert(abi.encodeWithSelector(ProjectNFT.ProjectNFT__NotRegisteredCollector.selector, attacker));
        vm.prank(attacker);
        nft.mintProject(
            address(usdc), "Test", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function test_mintProject_revertWhenCollectorBlacklisted() public {
        vm.prank(kycAdmin);
        accessReg.blacklistCollector(collector);

        vm.expectRevert(abi.encodeWithSelector(ProjectNFT.ProjectNFT__CollectorBlacklisted.selector, collector));
        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Test", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function test_mintProject_revertOnZeroVolumeKg() public {
        vm.expectRevert(ProjectNFT.ProjectNFT__ZeroValue.selector);
        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Test", 0, COLLATERAL,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function test_mintProject_revertOnZeroCollateral() public {
        vm.expectRevert(ProjectNFT.ProjectNFT__ZeroValue.selector);
        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Test", VOLUME_KG, 0,
            FUNDING_DURATION, REPAYMENT_DURATION, "QmTest"
        );
    }

    function test_mintProject_revertOnZeroRepaymentDuration() public {
        vm.expectRevert(ProjectNFT.ProjectNFT__ZeroValue.selector);
        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Test", VOLUME_KG, COLLATERAL,
            FUNDING_DURATION, 0, "QmTest"
        );
    }

    function test_mintProject_revertOnTooShortFundingDuration() public {
        vm.expectRevert(ProjectNFT.ProjectNFT__InvalidFundingDuration.selector);
        vm.prank(collector);
        nft.mintProject(
            address(usdc), "Test", VOLUME_KG, COLLATERAL,
            30 minutes, REPAYMENT_DURATION, "QmTest"
        );
    }

    // 3. VERIFY PROJECT
    function test_verifyProject_setsStatusAndFlag() public {
        uint256 pid = _mintProject();

        vm.prank(kycAdmin);
        nft.verifyProject(pid);

        DataTypes.Project memory p = pool.getProject(pid);
        assertTrue(p.collateralVerified);
        assertEq(uint8(p.status), uint8(DataTypes.ProjectStatus.OPEN));
    }

    function test_verifyProject_emitsEvent() public {
        uint256 pid = _mintProject();

        vm.expectEmit(true, true, false, false, address(nft));
        emit IProjectNFT.ProjectVerified(pid, kycAdmin);

        vm.prank(kycAdmin);
        nft.verifyProject(pid);
    }

    function test_verifyProject_revertWhenNotPendingVerification() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert();
        vm.prank(kycAdmin);
        nft.verifyProject(pid);
    }

    function test_verifyProject_revertWhenCallerLacksRole() public {
        uint256 pid = _mintProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, KYC_ADMIN_ROLE
        ));
        vm.prank(attacker);
        nft.verifyProject(pid);
    }

    // 4. REJECT PROJECT
    function test_rejectProject_setsStatusRejected() public {
        uint256 pid = _mintProject();

        vm.prank(kycAdmin);
        nft.rejectProject(pid);

        DataTypes.Project memory p = pool.getProject(pid);
        assertEq(uint8(p.status), uint8(DataTypes.ProjectStatus.REJECTED));
    }

    function test_rejectProject_emitsProjectRejected() public {
        uint256 pid = _mintProject();

        vm.expectEmit(true, false, false, false, address(nft));
        emit IProjectNFT.ProjectRejected(pid);

        vm.prank(kycAdmin);
        nft.rejectProject(pid);
    }

    function test_rejectProject_revertWhenNotPendingVerification() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert();
        vm.prank(kycAdmin);
        nft.rejectProject(pid);
    }

    function test_rejectProject_revertWhenCallerLacksRole() public {
        uint256 pid = _mintProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, KYC_ADMIN_ROLE
        ));
        vm.prank(attacker);
        nft.rejectProject(pid);
    }

    function test_rejectProject_terminalState_cannotVerifyAfterRejection() public {
        uint256 pid = _mintProject();

        vm.prank(kycAdmin);
        nft.rejectProject(pid);

        vm.expectRevert();
        vm.prank(kycAdmin);
        nft.verifyProject(pid);
    }

    // 5. INVEST
    function test_invest_recordsInvestmentAndUpdatesFunded() public {
        uint256 pid = _createVerifiedProject();

        vm.prank(inv1);
        pool.invest(pid, 300e6);

        DataTypes.Project memory p = pool.getProject(pid);
        assertEq(p.totalFunded, 300e6);

        DataTypes.Investment memory inv = pool.getInvestment(pid, inv1);
        assertEq(inv.investor, inv1);
        assertEq(inv.amount,   300e6);
        assertFalse(inv.claimed);
    }

    function test_invest_depositsIntoTreasury() public {
        uint256 pid = _createVerifiedProject();

        vm.prank(inv1);
        pool.invest(pid, 300e6);

        assertEq(treasury.projectBalances(pid, address(usdc)), 300e6);
        assertEq(usdc.balanceOf(address(treasury)), 300e6);
    }

    function test_invest_emitsInvestedEvent() public {
        uint256 pid = _createVerifiedProject();

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.Invested(pid, inv1, 300e6, 300e6);

        vm.prank(inv1);
        pool.invest(pid, 300e6);
    }

    function test_invest_autoFundsWhenCapReached() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 500e6);
        vm.prank(inv2); pool.invest(pid, 500e6);

        vm.expectEmit(true, false, false, true, address(pool));
        emit ILendingPool.ProjectAutoFunded(pid, MAX_FUNDING);

        vm.prank(inv3);
        pool.invest(pid, 500e6);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.FUNDED));
    }

    function test_invest_revertWhenProjectNotOpen() public {
        uint256 pid = _fundedProject();

        usdc.mint(attacker, 100e6);
        vm.prank(attacker); usdc.approve(address(pool), 100e6);

        vm.expectRevert();
        vm.prank(attacker);
        pool.invest(pid, 100e6);
    }

    function test_invest_revertAfterFundingDeadline() public {
        uint256 pid = _createVerifiedProject();

        vm.warp(block.timestamp + FUNDING_DURATION + 1);

        vm.expectRevert(abi.encodeWithSelector(
            LendingPool.LendingPool__FundingDeadlineExpired.selector, pid, pool.getProject(pid).fundingDeadline
        ));
        vm.prank(inv1);
        pool.invest(pid, 100e6);
    }

    function test_invest_revertWhenAlreadyInvested() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 100e6);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__AlreadyInvested.selector, pid, inv1));
        vm.prank(inv1);
        pool.invest(pid, 100e6);
    }

    function test_invest_revertWhenExceedsCapacity() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert(abi.encodeWithSelector(
            LendingPool.LendingPool__ExceedsCapacity.selector, MAX_FUNDING + 1, MAX_FUNDING
        ));
        vm.prank(inv1);
        pool.invest(pid, MAX_FUNDING + 1);
    }

    function test_invest_revertOnZeroAmount() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert(LendingPool.LendingPool__ZeroValue.selector);
        vm.prank(inv1);
        pool.invest(pid, 0);
    }

    function test_invest_revertWhenProjectPendingVerification() public {
        uint256 pid = _mintProject();

        vm.expectRevert();
        vm.prank(inv1);
        pool.invest(pid, 100e6);
    }

    function test_invest_revertWhenProjectRejected() public {
        uint256 pid = _mintProject();

        vm.prank(kycAdmin);
        nft.rejectProject(pid);

        vm.expectRevert();
        vm.prank(inv1);
        pool.invest(pid, 100e6);
    }

    // 6. CLOSE FUNDING (MANUAL)
    function test_closeFunding_setsStatusToClosed() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 100e6);

        vm.prank(collector);
        pool.closeFunding(pid);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.CLOSED));
    }

    function test_closeFunding_emitsEvent() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 100e6);

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.ProjectManuallyClosed(pid, collector, 100e6);

        vm.prank(collector);
        pool.closeFunding(pid);
    }

    function test_closeFunding_revertWhenNotOwner() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 100e6);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NotProjectOwner.selector, pid, attacker));
        vm.prank(attacker);
        pool.closeFunding(pid);
    }

    function test_closeFunding_revertWhenNoFunds() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NoFundsToClose.selector, pid));
        vm.prank(collector);
        pool.closeFunding(pid);
    }

    // 7. DISBURSE FUNDS
    function test_disburseFunds_transfersTotalFundedToCollector() public {
        uint256 pid = _fundedProject();

        uint256 collectorBefore = usdc.balanceOf(collector);
        vm.prank(operator);
        pool.disburseFunds(pid);

        assertEq(usdc.balanceOf(collector) - collectorBefore, MAX_FUNDING);
        assertEq(treasury.projectBalances(pid, address(usdc)), 0);
    }

    function test_disburseFunds_setsRepaymentDeadline() public {
        uint256 pid = _fundedProject();
        uint256 disbursalTime = block.timestamp;

        vm.prank(operator);
        pool.disburseFunds(pid);

        assertEq(pool.getProject(pid).repaymentDeadline, disbursalTime + REPAYMENT_DURATION);
    }

    function test_disburseFunds_setsStatusDisbursed() public {
        uint256 pid = _disbursedProject();
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.DISBURSED));
    }

    function test_disburseFunds_worksOnManuallyClosed() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(inv1); pool.invest(pid, 200e6);

        vm.prank(collector); pool.closeFunding(pid);

        vm.prank(operator);
        pool.disburseFunds(pid);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.DISBURSED));
    }

    function test_disburseFunds_emitsEvent() public {
        uint256 pid = _fundedProject();

        vm.expectEmit(true, true, false, false, address(pool));
        emit ILendingPool.FundsDisbursed(pid, collector, MAX_FUNDING, 0);

        vm.prank(operator);
        pool.disburseFunds(pid);
    }

    function test_disburseFunds_revertWhenCallerLacksRole() public {
        uint256 pid = _fundedProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, OPERATOR_ROLE
        ));
        vm.prank(attacker);
        pool.disburseFunds(pid);
    }

    // 8. RECORD BUYER PAYMENT
    function test_recordBuyerPayment_fullPayment_setsDistributionCorrectly() public {
        uint256 pid = _disbursedProject();

        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.totalInvestorReturn, INVESTOR_RETURN);
        assertEq(dist.platformFee,         PLATFORM_FEE);
        assertEq(dist.collectorRemainder,  BUYER_OVERPAYS - FULL_REQUIRED);
        assertTrue(dist.distributed);
    }

    function test_recordBuyerPayment_immediatelyReleasesPlatformFee() public {
        uint256 pid = _disbursedProject();
        uint256 walletBefore = usdc.balanceOf(platformWallet);

        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);

        assertEq(usdc.balanceOf(platformWallet) - walletBefore, PLATFORM_FEE);
    }

    function test_recordBuyerPayment_setsStatusToSettled() public {
        uint256 pid = _disbursedProject();

        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.SETTLED));
    }

    function test_recordBuyerPayment_emitsEvents() public {
        uint256 pid = _disbursedProject();

        vm.expectEmit(true, false, false, true, address(pool));
        emit ILendingPool.BuyerPaymentRecorded(pid, BUYER_OVERPAYS);

        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);
    }

    function test_recordBuyerPayment_partialPayment_waterfallInvestorsFirst() public {
        uint256 pid = _disbursedProject();

        vm.prank(operator);
        pool.recordBuyerPayment(pid, INVESTOR_RETURN);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.totalInvestorReturn, INVESTOR_RETURN);
        assertEq(dist.platformFee,         0);
        assertEq(dist.collectorRemainder,  0);
    }

    function test_recordBuyerPayment_betweenInvestorAndFull() public {
        uint256 pid = _disbursedProject();

        vm.prank(operator);
        pool.recordBuyerPayment(pid, INVESTOR_RETURN + 50e6);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.totalInvestorReturn, INVESTOR_RETURN);
        assertEq(dist.platformFee,         50e6);
        assertEq(dist.collectorRemainder,  0);
    }

    function test_recordBuyerPayment_severeUnderpay_investorsShareProRata() public {
        uint256 pid = _disbursedProject();

        vm.prank(operator);
        pool.recordBuyerPayment(pid, INVESTOR_RETURN / 2);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.totalInvestorReturn, INVESTOR_RETURN / 2);
        assertEq(dist.platformFee,         0);
        assertEq(dist.collectorRemainder,  0);
    }

    function test_recordBuyerPayment_zeroRemainderAutoMarksCollectorClaimed() public {
        uint256 pid = _disbursedProject();
        vm.prank(operator);
        pool.recordBuyerPayment(pid, FULL_REQUIRED);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.collectorRemainder, 0);
        assertTrue(dist.collectorClaimed);
    }

    function test_recordBuyerPayment_revertOnZeroAmount() public {
        uint256 pid = _disbursedProject();

        vm.expectRevert(LendingPool.LendingPool__ZeroValue.selector);
        vm.prank(operator);
        pool.recordBuyerPayment(pid, 0);
    }

    function test_recordBuyerPayment_revertWhenCallerLacksRole() public {
        uint256 pid = _disbursedProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, OPERATOR_ROLE
        ));
        vm.prank(attacker);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);
    }

    // 9. CLAIM RETURN (INVESTORS)
    function test_claimInvestorFunds_transfersProportionalReturn() public {
        uint256 pid = _settledProject();

        uint256 before = usdc.balanceOf(inv1);
        vm.prank(inv1);
        pool.claimInvestorFunds(pid);

        uint256 expected = (INVESTOR_RETURN * 500e6) / MAX_FUNDING;
        assertEq(usdc.balanceOf(inv1) - before, expected);
    }

    function test_claimInvestorFunds_marksInvestmentAsClaimed() public {
        uint256 pid = _settledProject();

        vm.prank(inv1);
        pool.claimInvestorFunds(pid);

        assertTrue(pool.getInvestment(pid, inv1).claimed);
    }

    function test_claimInvestorFunds_emitsInvestorFundsClaimedEvent() public {
        uint256 pid = _settledProject();
        uint256 expected = (INVESTOR_RETURN * 500e6) / MAX_FUNDING;

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.InvestorFundsClaimed(pid, inv1, expected);

        vm.prank(inv1);
        pool.claimInvestorFunds(pid);
    }

    function test_claimInvestorFunds_revertWhenAlreadyClaimed() public {
        uint256 pid = _settledProject();
        vm.prank(inv1); pool.claimInvestorFunds(pid);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__AlreadyClaimed.selector, pid, inv1));
        vm.prank(inv1);
        pool.claimInvestorFunds(pid);
    }

    function test_claimInvestorFunds_revertWhenNotInvestor() public {
        uint256 pid = _settledProject();

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NotInvestor.selector, pid, attacker));
        vm.prank(attacker);
        pool.claimInvestorFunds(pid);
    }

    function test_claimInvestorFunds_revertWhenNotSettled() public {
        uint256 pid = _disbursedProject();

        vm.expectRevert();
        vm.prank(inv1);
        pool.claimInvestorFunds(pid);
    }

    // 10. CLAIM (COLLECTOR)
    function test_claimCollectorFunds_transfersRemainderToCollector() public {
        uint256 pid = _settledProject();
        uint256 expectedRemainder = BUYER_OVERPAYS - FULL_REQUIRED;

        uint256 before = usdc.balanceOf(collector);
        vm.prank(collector);
        pool.claimCollectorFunds(pid);

        assertEq(usdc.balanceOf(collector) - before, expectedRemainder);
    }

    function test_claimCollectorFunds_marksCollectorClaimed() public {
        uint256 pid = _settledProject();

        vm.prank(collector);
        pool.claimCollectorFunds(pid);

        assertTrue(pool.getDistribution(pid).collectorClaimed);
    }

    function test_claimCollectorFunds_emitsEvent() public {
        uint256 pid = _settledProject();
        uint256 expectedRemainder = BUYER_OVERPAYS - FULL_REQUIRED;

        vm.expectEmit(true, true, false, true, address(pool));
        emit ILendingPool.CollectorFundsClaimed(pid, collector, expectedRemainder);

        vm.prank(collector);
        pool.claimCollectorFunds(pid);
    }

    function test_claimCollectorFunds_revertWhenNotOwner() public {
        uint256 pid = _settledProject();

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NotProjectOwner.selector, pid, attacker));
        vm.prank(attacker);
        pool.claimCollectorFunds(pid);
    }

    function test_claimCollectorFunds_revertWhenAlreadyClaimed() public {
        uint256 pid = _settledProject();
        vm.prank(collector); pool.claimCollectorFunds(pid);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__RemainderAlreadyClaimed.selector, pid));
        vm.prank(collector);
        pool.claimCollectorFunds(pid);
    }

    function test_claimCollectorFunds_revertWhenNoRemainder() public {
        uint256 pid = _disbursedProject();
        vm.prank(operator);
        pool.recordBuyerPayment(pid, FULL_REQUIRED);

        vm.expectRevert(abi.encodeWithSelector(LendingPool.LendingPool__NoRemainderToClaim.selector, pid));
        vm.prank(collector);
        pool.claimCollectorFunds(pid);
    }

    // 11. FULL FLOW (3 INVESTORS → AUTO-CLOSE → COMPLETED)
    function test_fullFlow_happyPath() public {
        uint256 pid = _mintProject();
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.PENDING_VERIFICATION));

        vm.prank(kycAdmin);
        nft.verifyProject(pid);
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.OPEN));

        vm.prank(inv1); pool.invest(pid, 500e6);
        vm.prank(inv2); pool.invest(pid, 500e6);
        vm.prank(inv3); pool.invest(pid, 500e6);
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.FUNDED));
        assertEq(treasury.projectBalances(pid, address(usdc)), MAX_FUNDING);

        vm.prank(operator);
        pool.disburseFunds(pid);
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.DISBURSED));
        assertEq(usdc.balanceOf(collector), MAX_FUNDING);

        vm.prank(operator);
        pool.recordBuyerPayment(pid, BUYER_OVERPAYS);
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.SETTLED));
        assertEq(usdc.balanceOf(platformWallet), PLATFORM_FEE);
        assertEq(treasury.projectBalances(pid, address(usdc)), INVESTOR_RETURN + (BUYER_OVERPAYS - FULL_REQUIRED));

        uint256 expectedPerInvestor = (INVESTOR_RETURN * 500e6) / MAX_FUNDING;
        vm.prank(inv1); pool.claimInvestorFunds(pid);
        vm.prank(inv2); pool.claimInvestorFunds(pid);
        vm.prank(inv3); pool.claimInvestorFunds(pid);
        assertEq(usdc.balanceOf(inv1), MAX_FUNDING - 500e6 + expectedPerInvestor);

        uint256 collectorRemBefore = usdc.balanceOf(collector);
        vm.prank(collector);
        pool.claimCollectorFunds(pid);
        assertEq(usdc.balanceOf(collector) - collectorRemBefore, BUYER_OVERPAYS - FULL_REQUIRED);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.COMPLETED));
    }

    // 12. FULL FLOW: MANUAL CLOSE + PARTIAL BUYER PAYMENT
    function test_fullFlow_manualClose_partialPayment() public {
        uint256 pid = _mintProject();
        vm.prank(kycAdmin); nft.verifyProject(pid);
        vm.prank(inv1); pool.invest(pid, 200e6);

        vm.prank(collector); pool.closeFunding(pid);
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.CLOSED));

        vm.prank(operator); pool.disburseFunds(pid);
        assertEq(usdc.balanceOf(collector), 200e6);

        vm.prank(operator);
        pool.recordBuyerPayment(pid, 150e6);

        DataTypes.Distribution memory dist = pool.getDistribution(pid);
        assertEq(dist.totalInvestorReturn, 150e6);
        assertEq(dist.platformFee,         0);
        assertEq(dist.collectorRemainder,  0);

        uint256 before = usdc.balanceOf(inv1);
        vm.prank(inv1); pool.claimInvestorFunds(pid);
        assertEq(usdc.balanceOf(inv1) - before, 150e6);

        // collectorRemainder == 0 → collectorClaimed auto-set → COMPLETED
        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.COMPLETED));
    }

    // 13. MARK DEFAULTED
    function test_markDefaulted_setsStatusDefaulted() public {
        uint256 pid = _disbursedProject();
        uint256 deadline = pool.getProject(pid).repaymentDeadline;
        vm.warp(deadline + pool.GRACE_PERIOD() + 1);

        vm.prank(operator);
        pool.markDefaulted(pid);

        assertEq(uint8(pool.getProject(pid).status), uint8(DataTypes.ProjectStatus.DEFAULTED));
    }

    function test_markDefaulted_emitsEvent() public {
        uint256 pid = _disbursedProject();
        uint256 deadline = pool.getProject(pid).repaymentDeadline;
        vm.warp(deadline + pool.GRACE_PERIOD() + 1);

        vm.expectEmit(true, false, false, false, address(pool));
        emit ILendingPool.ProjectDefaulted(pid);

        vm.prank(operator);
        pool.markDefaulted(pid);
    }

    function test_markDefaulted_revertWhenGracePeriodNotElapsed() public {
        uint256 pid = _disbursedProject();
        uint256 deadline = pool.getProject(pid).repaymentDeadline;

        vm.warp(deadline + pool.GRACE_PERIOD() - 1);

        vm.expectRevert(abi.encodeWithSelector(
            LendingPool.LendingPool__GracePeriodNotElapsed.selector, pid, deadline + pool.GRACE_PERIOD()
        ));
        vm.prank(operator);
        pool.markDefaulted(pid);
    }

    function test_markDefaulted_revertWhenNotDisbursed() public {
        uint256 pid = _fundedProject();

        vm.expectRevert();
        vm.prank(operator);
        pool.markDefaulted(pid);
    }

    function test_markDefaulted_revertWhenCallerLacksRole() public {
        uint256 pid = _disbursedProject();
        uint256 deadline = pool.getProject(pid).repaymentDeadline;
        vm.warp(deadline + pool.GRACE_PERIOD() + 1);

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, OPERATOR_ROLE
        ));
        vm.prank(attacker);
        pool.markDefaulted(pid);
    }

    // 14. SET ACCEPTED TOKEN
    function test_setAcceptedToken_addsAndRemoves() public {
        address newToken = makeAddr("newToken");
        assertFalse(pool.acceptedTokens(newToken));

        vm.prank(admin);
        pool.setAcceptedToken(newToken, true);
        assertTrue(pool.acceptedTokens(newToken));

        vm.prank(admin);
        pool.setAcceptedToken(newToken, false);
        assertFalse(pool.acceptedTokens(newToken));
    }

    function test_setAcceptedToken_revertOnZeroAddress() public {
        vm.expectRevert(LendingPool.LendingPool__ZeroAddress.selector);
        vm.prank(admin);
        pool.setAcceptedToken(address(0), true);
    }

    function test_setAcceptedToken_revertWhenCallerLacksRole() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
        ));
        vm.prank(attacker);
        pool.setAcceptedToken(address(usdc), false);
    }

    // 15. PAUSE / UNPAUSE
    function test_pause_blocksInvest() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(operator); pool.pause();

        vm.expectRevert();
        vm.prank(inv1);
        pool.invest(pid, 100e6);
    }

    function test_unpause_restoresNormalFlow() public {
        uint256 pid = _createVerifiedProject();
        vm.prank(operator); pool.pause();
        vm.prank(admin);    pool.unpause();

        vm.prank(inv1);
        pool.invest(pid, 100e6);
        assertEq(pool.getProject(pid).totalFunded, 100e6);
    }

    function test_pause_revertWhenCallerLacksRole() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, OPERATOR_ROLE
        ));
        vm.prank(attacker);
        pool.pause();
    }

    function test_unpause_revertWhenCallerLacksRole() public {
        vm.prank(operator); pool.pause();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
        ));
        vm.prank(attacker);
        pool.unpause();
    }

    // 16. SET PLATFORM WALLET
    function test_setPlatformWallet_updatesWallet() public {
        address newWallet = makeAddr("newWallet");

        vm.prank(admin);
        pool.setPlatformWallet(newWallet);

        assertEq(pool.platformWallet(), newWallet);
    }

    function test_setPlatformWallet_emitsEvent() public {
        address newWallet = makeAddr("newWallet");

        vm.expectEmit(true, false, false, false, address(pool));
        emit ILendingPool.PlatformWalletSet(newWallet);

        vm.prank(admin);
        pool.setPlatformWallet(newWallet);
    }

    function test_setPlatformWallet_revertOnZeroAddress() public {
        vm.expectRevert(LendingPool.LendingPool__ZeroAddress.selector);
        vm.prank(admin);
        pool.setPlatformWallet(address(0));
    }

    function test_setPlatformWallet_revertWhenCallerLacksRole() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
        ));
        vm.prank(attacker);
        pool.setPlatformWallet(makeAddr("newWallet"));
    }

    // 17. NEGATIVE ACCESS CONTROL TESTS
    function test_ac_randomAddressCannotCallVerifyProject() public {
        uint256 pid = _mintProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, KYC_ADMIN_ROLE
        ));
        vm.prank(attacker);
        nft.verifyProject(pid);
    }

    function test_ac_collectorCannotCallDisburseFunds() public {
        uint256 pid = _fundedProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, collector, OPERATOR_ROLE
        ));
        vm.prank(collector);
        pool.disburseFunds(pid);
    }

    function test_ac_investorCannotCallMarkDefaulted() public {
        uint256 pid = _disbursedProject();
        uint256 deadline = pool.getProject(pid).repaymentDeadline;
        vm.warp(deadline + pool.GRACE_PERIOD() + 1);

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, inv1, OPERATOR_ROLE
        ));
        vm.prank(inv1);
        pool.markDefaulted(pid);
    }

    function test_ac_randomAddressCannotCallTreasuryRelease() public {
        uint256 pid = _createVerifiedProject();

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, POOL_ROLE
        ));
        vm.prank(attacker);
        treasury.release(pid, address(usdc), 1e6, attacker);
    }
}
