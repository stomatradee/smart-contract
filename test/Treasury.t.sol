// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {Treasury} from "../src/core/Treasury.sol";
import {ITreasury} from "../src/interfaces/ITreasury.sol";
import {IAccessControl} from "@openzeppelin/contracts/access/IAccessControl.sol";


contract MockERC20 {
    string  public name;
    string  public symbol;
    uint8   public decimals;
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
        _transfer(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _transfer(from, to, amount);
        return true;
    }

    function _transfer(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}

contract ReentrantToken {
    Treasury internal immutable TREASURY_CONTRACT;
    uint256  internal projectId;
    uint256  public   attackCount;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    constructor(address _treasury) {
        TREASURY_CONTRACT = Treasury(_treasury);
    }

    function setup(uint256 _projectId) external { projectId = _projectId; }
    function mint(address to, uint256 amount) external { balanceOf[to] += amount; }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        balanceOf[msg.sender] -= amount;
        balanceOf[to]         += amount;

        attackCount++;
        try TREASURY_CONTRACT.release(projectId, address(this), amount, to) {
            // should never reach here
        } catch {
            // expected: ReentrancyGuard blocks re-entry
        }
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        return true;
    }
}


contract TreasuryTest is Test {
    // ACTORS
    address internal admin          = makeAddr("admin");
    address internal pool           = makeAddr("pool");
    address internal platformWallet = makeAddr("platformWallet");
    address internal investor       = makeAddr("investor");
    address internal collector      = makeAddr("collector");
    address internal attacker       = makeAddr("attacker");

    // CONTRACTS
    Treasury  internal treasury;
    MockERC20 internal usdc;
    MockERC20 internal usdt;

    // CONSTANTS
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal constant POOL_ROLE          = keccak256("POOL_ROLE");
    bytes32 internal constant EMERGENCY_ROLE     = keccak256("EMERGENCY_ROLE");

    uint256 internal constant PROJECT_ID = 1;
    uint256 internal constant AMOUNT_100 = 100e6;
    uint256 internal constant AMOUNT_50  = 50e6;

    // SETUP
    function setUp() public {
        treasury = new Treasury(admin, platformWallet);
        usdc     = new MockERC20("USD Coin", "USDC", 6);
        usdt     = new MockERC20("Tether",   "USDT", 6);

        vm.prank(admin);
        treasury.grantRole(POOL_ROLE, pool);

        usdc.mint(investor, AMOUNT_100);
        usdt.mint(investor, AMOUNT_100);
    }

    // 1. DEPLOYMENT
    function test_deployment_adminHasDefaultAdminRole() public view {
        assertTrue(treasury.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_deployment_poolRoleNotGrantedByDefault() public view {
        assertFalse(treasury.hasRole(POOL_ROLE, address(treasury)));
    }

    function test_deployment_platformWalletSetCorrectly() public view {
        assertEq(treasury.platformWallet(), platformWallet);
    }

    function test_deployment_projectBalancesZeroByDefault() public view {
        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), 0);
    }

    function test_deployment_revertWhenAdminIsZeroAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        new Treasury(address(0), platformWallet);
    }

    function test_deployment_revertWhenWalletIsZeroAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        new Treasury(admin, address(0));
    }

    function test_deployment_emitsPlatformWalletUpdatedOnConstruct() public {
        vm.expectEmit(true, true, false, false);
        emit ITreasury.PlatformWalletUpdated(address(0), platformWallet);
        new Treasury(admin, platformWallet);
    }

    function test_deployment_roleIdentifiersMatchExpectedHash() public view {
        assertEq(treasury.POOL_ROLE(),      POOL_ROLE);
        assertEq(treasury.EMERGENCY_ROLE(), EMERGENCY_ROLE);
        assertEq(POOL_ROLE,      keccak256("POOL_ROLE"));
        assertEq(EMERGENCY_ROLE, keccak256("EMERGENCY_ROLE"));
    }

    // 2. deposit()
    function test_deposit_creditsProjectBalance() public {
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), AMOUNT_100);
    }

    function test_deposit_emitsDepositedEvent() public {
        vm.expectEmit(true, true, true, true, address(treasury));
        emit ITreasury.Deposited(PROJECT_ID, address(usdc), investor, AMOUNT_100);

        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);
    }

    function test_deposit_accumulatesMultipleDeposits() public {
        usdc.mint(address(treasury), AMOUNT_50);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_50, investor);

        usdc.mint(address(treasury), AMOUNT_50);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_50, investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), AMOUNT_100);
        assertEq(usdc.balanceOf(address(treasury)), AMOUNT_100);
    }

    function test_deposit_revertWhenCallerLacksPoolRole() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, POOL_ROLE)
        );
        vm.prank(attacker);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);
    }

    function test_deposit_revertWhenCalledByAdmin() public {
        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, admin, POOL_ROLE)
        );
        vm.prank(admin);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);
    }

    function test_deposit_revertOnZeroAmount() public {
        vm.expectRevert(Treasury.Treasury__ZeroAmount.selector);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), 0, investor);
    }

    function test_deposit_revertOnZeroTokenAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(0), AMOUNT_100, investor);
    }

    function test_deposit_revertOnZeroFromAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, address(0));
    }

    function test_deposit_doesNotAffectOtherProjects() public {
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);

        assertEq(treasury.projectBalances(PROJECT_ID + 1, address(usdc)), 0);
    }

    // 3. release()
    function _depositFirst() internal {
        usdc.mint(address(treasury), AMOUNT_100);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);
    }

    function test_release_debitsProjectBalance() public {
        _depositFirst();

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), AMOUNT_50);
    }

    function test_release_transfersTokensToRecipient() public {
        _depositFirst();

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);

        assertEq(usdc.balanceOf(collector),         AMOUNT_50);
        assertEq(usdc.balanceOf(address(treasury)), AMOUNT_50);
    }

    function test_release_emitsReleasedEvent() public {
        _depositFirst();

        vm.expectEmit(true, true, true, true, address(treasury));
        emit ITreasury.Released(PROJECT_ID, address(usdc), collector, AMOUNT_50);

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);
    }

    function test_release_fullBalanceRelease() public {
        _depositFirst();

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_100, collector);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), 0);
        assertEq(usdc.balanceOf(collector),         AMOUNT_100);
        assertEq(usdc.balanceOf(address(treasury)), 0);
    }

    function test_release_multipleReleases() public {
        _depositFirst();

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), 0);
        assertEq(usdc.balanceOf(collector), AMOUNT_50);
        assertEq(usdc.balanceOf(investor),  AMOUNT_100 + AMOUNT_50);
    }

    function test_release_revertWhenCallerLacksPoolRole() public {
        _depositFirst();

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, POOL_ROLE)
        );
        vm.prank(attacker);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);
    }

    function test_release_revertOnZeroAmount() public {
        _depositFirst();

        vm.expectRevert(Treasury.Treasury__ZeroAmount.selector);
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), 0, collector);
    }

    function test_release_revertOnZeroTokenAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(0), AMOUNT_50, collector);
    }

    function test_release_revertOnZeroToAddress() public {
        _depositFirst();

        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, address(0));
    }

    function test_release_revertWhenInsufficientBalance() public {
        _depositFirst();

        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.Treasury__InsufficientProjectBalance.selector,
                PROJECT_ID, address(usdc), AMOUNT_100 + 1, AMOUNT_100
            )
        );
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_100 + 1, collector);
    }

    function test_release_revertWhenProjectBalanceIsZero() public {
        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.Treasury__InsufficientProjectBalance.selector,
                PROJECT_ID, address(usdc), AMOUNT_50, 0
            )
        );
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);
    }

    function test_release_doesNotAffectOtherProjectBalances() public {
        usdc.mint(address(treasury), AMOUNT_100);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);

        usdc.mint(address(treasury), AMOUNT_100);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID + 1, address(usdc), AMOUNT_100, investor);

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_100, collector);

        assertEq(treasury.projectBalances(PROJECT_ID,     address(usdc)), 0);
        assertEq(treasury.projectBalances(PROJECT_ID + 1, address(usdc)), AMOUNT_100);
    }

    // 4. setPlatformWallet()
    function test_setPlatformWallet_updatesWallet() public {
        address newWallet = makeAddr("newWallet");

        vm.prank(admin);
        treasury.setPlatformWallet(newWallet);

        assertEq(treasury.platformWallet(), newWallet);
    }

    function test_setPlatformWallet_emitsPlatformWalletUpdated() public {
        address newWallet = makeAddr("newWallet");

        vm.expectEmit(true, true, false, false, address(treasury));
        emit ITreasury.PlatformWalletUpdated(platformWallet, newWallet);

        vm.prank(admin);
        treasury.setPlatformWallet(newWallet);
    }

    function test_setPlatformWallet_revertOnZeroAddress() public {
        vm.expectRevert(Treasury.Treasury__ZeroAddress.selector);
        vm.prank(admin);
        treasury.setPlatformWallet(address(0));
    }

    function test_setPlatformWallet_revertWhenCallerLacksAdminRole() public {
        address newWallet = makeAddr("newWallet");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, pool, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(pool);
        treasury.setPlatformWallet(newWallet);
    }

    function test_setPlatformWallet_revertWhenCalledByAttacker() public {
        address newWallet = makeAddr("newWallet");

        vm.expectRevert(
            abi.encodeWithSelector(IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE)
        );
        vm.prank(attacker);
        treasury.setPlatformWallet(newWallet);
    }

    function test_setPlatformWallet_doesNotMoveExistingFunds() public {
        _depositFirst();

        address newWallet = makeAddr("newWallet");
        vm.prank(admin);
        treasury.setPlatformWallet(newWallet);

        assertEq(usdc.balanceOf(address(treasury)), AMOUNT_100);
        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), AMOUNT_100);
    }

    // 5. MULTI-PROJECT / MULTI-TOKEN ACCOUNTING
    function test_accounting_differentTokensSameProject() public {
        usdc.mint(address(treasury), AMOUNT_100);
        usdt.mint(address(treasury), AMOUNT_50);

        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), AMOUNT_100, investor);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdt), AMOUNT_50,  investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), AMOUNT_100);
        assertEq(treasury.projectBalances(PROJECT_ID, address(usdt)), AMOUNT_50);
    }

    function test_accounting_sameTokenDifferentProjects() public {
        usdc.mint(address(treasury), AMOUNT_100 * 2);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID,     address(usdc), AMOUNT_100, investor);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID + 1, address(usdc), AMOUNT_100, investor);

        assertEq(treasury.projectBalances(PROJECT_ID,     address(usdc)), AMOUNT_100);
        assertEq(treasury.projectBalances(PROJECT_ID + 1, address(usdc)), AMOUNT_100);
        assertEq(usdc.balanceOf(address(treasury)), AMOUNT_100 * 2);
    }

    function test_accounting_releaseOnlyDeductsCorrectSlot() public {
        usdc.mint(address(treasury), AMOUNT_100 * 2);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID,     address(usdc), AMOUNT_100, investor);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID + 1, address(usdc), AMOUNT_100, investor);

        vm.prank(pool);
        treasury.release(PROJECT_ID + 1, address(usdc), AMOUNT_50, collector);

        assertEq(treasury.projectBalances(PROJECT_ID,     address(usdc)), AMOUNT_100);
        assertEq(treasury.projectBalances(PROJECT_ID + 1, address(usdc)), AMOUNT_50);
    }

    function test_accounting_depositThenFullCycle() public {
        _depositFirst();

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, collector);
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), AMOUNT_50, investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), 0);
        assertEq(usdc.balanceOf(address(treasury)), 0);
        assertEq(usdc.balanceOf(collector),         AMOUNT_50);
        assertEq(usdc.balanceOf(investor),          AMOUNT_100 + AMOUNT_50);
    }

    // 6. REENTRANCY
    function test_reentrancy_releaseIsProtected() public {
        // ReentrantToken.transferFrom skips allowance checks, so deposit works without approve.
        ReentrantToken rToken = new ReentrantToken(address(treasury));
        rToken.setup(PROJECT_ID);
        rToken.mint(address(treasury), AMOUNT_100);

        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(rToken), AMOUNT_100, investor);
        assertEq(treasury.projectBalances(PROJECT_ID, address(rToken)), AMOUNT_100);

        // During release, rToken.transfer() attempts a reentrant release().
        // ReentrancyGuard blocks it; the inner call reverts and is swallowed by try/catch.
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(rToken), AMOUNT_50, collector);

        assertEq(rToken.attackCount(), 1); // reentrant attempt happened exactly once
        assertEq(treasury.projectBalances(PROJECT_ID, address(rToken)), AMOUNT_50);
    }

    // 7. FUZZ
    function testFuzz_deposit_creditsExactAmount(uint96 amount) public {
        vm.assume(amount > 0);
        usdc.mint(address(treasury), amount);

        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), amount, investor);

        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), amount);
        assertEq(usdc.balanceOf(address(treasury)), amount);
    }

    function testFuzz_release_correctRemainder(uint96 deposit, uint96 releaseAmt) public {
        vm.assume(deposit > 0);
        vm.assume(releaseAmt > 0 && releaseAmt <= deposit);

        usdc.mint(address(treasury), deposit);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), deposit, investor);

        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), releaseAmt, collector);

        uint256 expected = uint256(deposit) - uint256(releaseAmt);
        assertEq(treasury.projectBalances(PROJECT_ID, address(usdc)), expected);
        assertEq(usdc.balanceOf(collector),         releaseAmt);
        assertEq(usdc.balanceOf(address(treasury)), expected);
    }

    function testFuzz_release_revertWhenExceedsBalance(uint96 deposit, uint96 excess) public {
        vm.assume(deposit > 0);
        vm.assume(excess > 0);
        uint256 releaseAmt = uint256(deposit) + uint256(excess);

        usdc.mint(address(treasury), deposit);
        vm.prank(pool);
        treasury.deposit(PROJECT_ID, address(usdc), deposit, investor);

        vm.expectRevert(
            abi.encodeWithSelector(
                Treasury.Treasury__InsufficientProjectBalance.selector,
                PROJECT_ID, address(usdc), releaseAmt, uint256(deposit)
            )
        );
        vm.prank(pool);
        treasury.release(PROJECT_ID, address(usdc), releaseAmt, collector);
    }

    function testFuzz_setPlatformWallet_anyNonZeroAddress(address wallet) public {
        vm.assume(wallet != address(0));

        vm.prank(admin);
        treasury.setPlatformWallet(wallet);

        assertEq(treasury.platformWallet(), wallet);
    }
}
