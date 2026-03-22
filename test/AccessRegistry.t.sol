// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {AccessRegistry}  from "../src/access/AccessRegistry.sol";
import {IAccessRegistry} from "../src/interfaces/IAccessRegistry.sol";
import {IAccessControl}  from "@openzeppelin/contracts/access/IAccessControl.sol";

contract AccessRegistryTest is Test {
    // ACTORS
    address internal admin    = makeAddr("admin");
    address internal kycAdmin = makeAddr("kycAdmin");
    address internal pool     = makeAddr("pool");
    address internal alice    = makeAddr("alice");
    address internal bob      = makeAddr("bob");
    address internal attacker = makeAddr("attacker");

    // CONTRACT UNDER TEST
    AccessRegistry internal registry;

    // ROLE IDENTIFIERS
    bytes32 internal constant DEFAULT_ADMIN_ROLE = 0x00;
    bytes32 internal kycAdminRole;
    bytes32 internal operatorRole;
    bytes32 internal poolRole;

    // SETUP
    function setUp() public {
        registry = new AccessRegistry(admin);

        kycAdminRole = registry.KYC_ADMIN_ROLE();
        operatorRole = registry.OPERATOR_ROLE();
        poolRole     = registry.POOL_ROLE();

        vm.startPrank(admin);
        registry.grantRole(kycAdminRole, kycAdmin);
        registry.grantRole(poolRole,     pool);
        vm.stopPrank();
    }

    // 1. DEPLOYMENT
    function test_deployment_adminHasDefaultAdminRole() public view {
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, admin));
    }

    function test_deployment_contractHasNoDefaultAdminRole() public view {
        assertFalse(registry.hasRole(DEFAULT_ADMIN_ROLE, address(registry)));
    }

    function test_deployment_subRolesAssigned() public view {
        assertTrue(registry.hasRole(kycAdminRole, kycAdmin));
        assertTrue(registry.hasRole(poolRole,     pool));
    }

    function test_deployment_noCollectorRegisteredByDefault() public view {
        assertFalse(registry.isRegisteredCollector(alice));
        assertFalse(registry.isRegisteredCollector(bob));
    }

    function test_deployment_noCollectorBlacklistedByDefault() public view {
        assertFalse(registry.isBlacklisted(alice));
    }

    function test_deployment_revertWhenAdminIsZeroAddress() public {
        vm.expectRevert(AccessRegistry.AccessRegistry__ZeroAddress.selector);
        new AccessRegistry(address(0));
    }

    function test_deployment_roleIdentifiersMatchExpectedHash() public view {
        assertEq(kycAdminRole, keccak256("KYC_ADMIN_ROLE"));
        assertEq(operatorRole, keccak256("OPERATOR_ROLE"));
        assertEq(poolRole,     keccak256("POOL_ROLE"));
    }

    // 2. REGISTER COLLECTOR
    function test_registerCollector_setsProfileData() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        IAccessRegistry.CollectorProfile memory profile = registry.getCollectorProfile(alice);

        assertTrue(profile.exists);
        assertEq(profile.profileURI,        "https://gateway.pinata.cloud/ipfs/QmAliceProfile");
        assertEq(profile.totalProjects,     0);
        assertEq(profile.completedProjects, 0);
        assertEq(profile.defaultedProjects, 0);
        assertEq(profile.registeredAt,      block.timestamp);
    }

    function test_registerCollector_setsRegistered() public {
        assertFalse(registry.isRegisteredCollector(alice));

        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        assertTrue(registry.isRegisteredCollector(alice));
    }

    function test_registerCollector_doesNotAutoBlacklist() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        assertFalse(registry.isBlacklisted(alice));
        assertTrue(registry.isEligibleCollector(alice));
    }

    function test_registerCollector_emitsCollectorRegistered() public {
        vm.expectEmit(true, false, false, true, address(registry));
        emit IAccessRegistry.CollectorRegistered(alice, "https://gateway.pinata.cloud/ipfs/QmAliceProfile");

        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");
    }

    function test_registerCollector_revertOnEmptyURI() public {
        vm.expectRevert(AccessRegistry.AccessRegistry__EmptyURI.selector);
        vm.prank(alice);
        registry.registerCollector("");
    }

    function test_registerCollector_revertWhenAlreadyRegistered() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__AlreadyRegistered.selector, alice));
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile2");
    }

    function test_registerCollector_revertWhenCallerIsBlacklisted() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__Blacklisted.selector, alice));
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");
    }

    function test_registerCollector_doesNotAffectOtherCollectors() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        assertFalse(registry.getCollectorProfile(bob).exists);
        assertFalse(registry.isRegisteredCollector(bob));
    }

    // 3. UPDATE COLLECTOR PROFILE
    function test_updateCollectorProfile_byCollectorSucceeds() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceV1");

        vm.prank(alice);
        registry.updateCollectorProfile("QmAliceV2");

        assertEq(registry.getCollectorProfile(alice).profileURI, "https://gateway.pinata.cloud/ipfs/QmAliceV2");
    }

    function test_updateCollectorProfile_emitsEvent() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceV1");

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAccessRegistry.CollectorProfileUpdated(alice, "https://gateway.pinata.cloud/ipfs/QmAliceV2");

        vm.prank(alice);
        registry.updateCollectorProfile("QmAliceV2");
    }

    function test_updateCollectorProfile_revertOnEmptyURI() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceV1");

        vm.expectRevert(AccessRegistry.AccessRegistry__EmptyURI.selector);
        vm.prank(alice);
        registry.updateCollectorProfile("");
    }

    function test_updateCollectorProfile_revertWhenProfileNotFound() public {
        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__ProfileNotFound.selector, alice));
        vm.prank(alice);
        registry.updateCollectorProfile("QmAlice");
    }

    function test_updateCollectorProfile_revertWhenAttacker() public {
        vm.prank(alice);
        registry.registerCollector("QmAliceV1");

        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__ProfileNotFound.selector, attacker));
        vm.prank(attacker);
        registry.updateCollectorProfile("QmAttacker");
    }

    function test_updateCollectorProfile_kycAdminCanOnlyUpdateOwnProfile() public {
        // kycAdmin has no collector profile, so even with role they get ProfileNotFound
        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__ProfileNotFound.selector, kycAdmin));
        vm.prank(kycAdmin);
        registry.updateCollectorProfile("QmKYCAdmin");
    }

    // 4. BLACKLIST COLLECTOR
    function test_blacklistCollector_setsFlag() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        assertTrue(registry.isBlacklisted(alice));
    }

    function test_blacklistCollector_emitsCollectorBlacklisted() public {
        vm.expectEmit(true, false, false, false, address(registry));
        emit IAccessRegistry.CollectorBlacklisted(alice);

        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);
    }

    function test_blacklistCollector_doesNotAffectOtherAddresses() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        assertFalse(registry.isBlacklisted(bob));
    }

    function test_blacklistCollector_revertOnZeroAddress() public {
        vm.expectRevert(AccessRegistry.AccessRegistry__ZeroAddress.selector);
        vm.prank(kycAdmin);
        registry.blacklistCollector(address(0));
    }

    function test_blacklistCollector_revertWhenAlreadyBlacklisted() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        vm.expectRevert(abi.encodeWithSelector(AccessRegistry.AccessRegistry__AlreadyBlacklisted.selector, alice));
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);
    }

    function test_blacklistCollector_revertWhenCallerLacksRole() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, kycAdminRole
        ));
        vm.prank(attacker);
        registry.blacklistCollector(alice);
    }

    function test_blacklistCollector_worksOnRegisteredCollector() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        assertTrue(registry.isRegisteredCollector(alice));
        assertTrue(registry.isBlacklisted(alice));
        assertFalse(registry.isEligibleCollector(alice));
    }

    function test_blacklistCollector_worksOnUnregisteredAddress() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(bob);

        assertTrue(registry.isBlacklisted(bob));
        assertFalse(registry.isEligibleCollector(bob));
    }

    // 5. ISREGISTERED COLLECTOR
    function test_isRegisteredCollector_falseBeforeRegister() public view {
        assertFalse(registry.isRegisteredCollector(alice));
    }

    function test_isRegisteredCollector_trueAfterRegister() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        assertTrue(registry.isRegisteredCollector(alice));
    }

    function test_isRegisteredCollector_zeroAddressIsFalse() public view {
        assertFalse(registry.isRegisteredCollector(address(0)));
    }

    // 6. ISELIGIBLE COLLECTOR
    function test_isEligibleCollector_notRegisteredNotBlacklisted() public view {
        assertFalse(registry.isEligibleCollector(alice));
    }

    function test_isEligibleCollector_registeredNotBlacklisted() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        assertTrue(registry.isEligibleCollector(alice));
    }

    function test_isEligibleCollector_notRegisteredButBlacklisted() public {
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        assertFalse(registry.isEligibleCollector(alice));
    }

    function test_isEligibleCollector_registeredAndBlacklisted() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);

        assertFalse(registry.isEligibleCollector(alice));
    }

    function test_isEligibleCollector_zeroAddressIsNotEligible() public view {
        assertFalse(registry.isEligibleCollector(address(0)));
    }

    // 7. INCREMENT PROJECT / COMPLETED / DEFAULTED COUNTS
    function test_incrementProjectCount_incrementsByOne() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(pool);
        registry.incrementProjectCount(alice);

        assertEq(registry.getCollectorProfile(alice).totalProjects, 1);
    }

    function test_incrementCompletedCount_incrementsByOne() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(pool);
        registry.incrementCompletedCount(alice);

        assertEq(registry.getCollectorProfile(alice).completedProjects, 1);
    }

    function test_incrementDefaultedCount_incrementsByOne() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(pool);
        registry.incrementDefaultedCount(alice);

        assertEq(registry.getCollectorProfile(alice).defaultedProjects, 1);
    }

    function test_incrementCounters_silentlySkipsIfNoProfile() public {
        vm.startPrank(pool);
        registry.incrementProjectCount(bob);
        registry.incrementCompletedCount(bob);
        registry.incrementDefaultedCount(bob);
        vm.stopPrank();

        IAccessRegistry.CollectorProfile memory profile = registry.getCollectorProfile(bob);
        assertFalse(profile.exists);
        assertEq(profile.totalProjects,     0);
        assertEq(profile.completedProjects, 0);
        assertEq(profile.defaultedProjects, 0);
    }

    function test_incrementProjectCount_revertWhenCallerLacksPoolRole() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, poolRole
        ));
        vm.prank(attacker);
        registry.incrementProjectCount(alice);
    }

    function test_incrementCounters_emitReputationUpdated() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.prank(pool);
        registry.incrementProjectCount(alice);

        vm.expectEmit(true, false, false, true, address(registry));
        emit IAccessRegistry.CollectorReputationUpdated(alice, 1, 1, 0);

        vm.prank(pool);
        registry.incrementCompletedCount(alice);
    }

    function test_incrementCounters_multipleIncrements() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.startPrank(pool);
        registry.incrementProjectCount(alice);
        registry.incrementProjectCount(alice);
        registry.incrementProjectCount(alice);
        registry.incrementCompletedCount(alice);
        registry.incrementCompletedCount(alice);
        registry.incrementDefaultedCount(alice);
        vm.stopPrank();

        IAccessRegistry.CollectorProfile memory profile = registry.getCollectorProfile(alice);
        assertEq(profile.totalProjects,     3);
        assertEq(profile.completedProjects, 2);
        assertEq(profile.defaultedProjects, 1);
    }

    // 8. GET COLLECTOR PROFILE
    function test_getCollectorProfile_returnsCorrectData() public {
        uint256 ts = block.timestamp;

        vm.prank(alice);
        registry.registerCollector("QmAliceProfile");

        vm.startPrank(pool);
        registry.incrementProjectCount(alice);
        registry.incrementCompletedCount(alice);
        vm.stopPrank();

        IAccessRegistry.CollectorProfile memory profile = registry.getCollectorProfile(alice);

        assertTrue(profile.exists);
        assertEq(profile.profileURI,        "https://gateway.pinata.cloud/ipfs/QmAliceProfile");
        assertEq(profile.totalProjects,     1);
        assertEq(profile.completedProjects, 1);
        assertEq(profile.defaultedProjects, 0);
        assertEq(profile.registeredAt,      ts);
    }

    function test_getCollectorProfile_existsFalseForUnregistered() public view {
        IAccessRegistry.CollectorProfile memory profile = registry.getCollectorProfile(alice);

        assertFalse(profile.exists);
        assertEq(profile.profileURI,        "");
        assertEq(profile.totalProjects,     0);
        assertEq(profile.completedProjects, 0);
        assertEq(profile.defaultedProjects, 0);
        assertEq(profile.registeredAt,      0);
    }

    // 9. ROLE MANAGEMENT
    function test_roleManagement_adminCanGrantKYCAdminRole() public {
        address newKycAdmin = makeAddr("newKycAdmin");
        vm.prank(admin);
        registry.grantRole(kycAdminRole, newKycAdmin);
        assertTrue(registry.hasRole(kycAdminRole, newKycAdmin));
    }

    function test_roleManagement_adminCanRevokeKYCAdminRole() public {
        vm.prank(admin);
        registry.revokeRole(kycAdminRole, kycAdmin);
        assertFalse(registry.hasRole(kycAdminRole, kycAdmin));

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, kycAdmin, kycAdminRole
        ));
        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);
    }

    function test_roleManagement_adminCanGrantPoolRole() public {
        address newPool = makeAddr("newPool");
        vm.prank(admin);
        registry.grantRole(poolRole, newPool);
        assertTrue(registry.hasRole(poolRole, newPool));
    }

    function test_roleManagement_nonAdminCannotGrantRoles() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, DEFAULT_ADMIN_ROLE
        ));
        vm.prank(attacker);
        registry.grantRole(kycAdminRole, attacker);
    }

    function test_roleManagement_roleHolderCanRenounce() public {
        vm.prank(kycAdmin);
        registry.renounceRole(kycAdminRole, kycAdmin);
        assertFalse(registry.hasRole(kycAdminRole, kycAdmin));
    }

    function test_roleManagement_adminCanTransferAdminRole() public {
        address newAdmin = makeAddr("newAdmin");

        vm.startPrank(admin);
        registry.grantRole(DEFAULT_ADMIN_ROLE, newAdmin);
        registry.renounceRole(DEFAULT_ADMIN_ROLE, admin);
        vm.stopPrank();

        assertFalse(registry.hasRole(DEFAULT_ADMIN_ROLE, admin));
        assertTrue(registry.hasRole(DEFAULT_ADMIN_ROLE, newAdmin));
    }

    function test_roleManagement_roleAdminsAreDefaultAdminRole() public view {
        assertEq(registry.getRoleAdmin(kycAdminRole), DEFAULT_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(operatorRole),  DEFAULT_ADMIN_ROLE);
        assertEq(registry.getRoleAdmin(poolRole),      DEFAULT_ADMIN_ROLE);
    }

    // 10. EDGE CASES & FUZZ
    function testFuzz_registerCollector_anyNonBlacklistedNonZeroAddress(address collector) public {
        vm.assume(collector != address(0));
        vm.assume(!registry.isBlacklisted(collector));

        vm.prank(collector);
        registry.registerCollector("QmFuzzProfile");

        assertTrue(registry.isRegisteredCollector(collector));
        assertTrue(registry.isEligibleCollector(collector));
    }

    function testFuzz_blacklistCollector_anyNonZeroAddress(address collector) public {
        vm.assume(collector != address(0));

        vm.prank(kycAdmin);
        registry.blacklistCollector(collector);

        assertTrue(registry.isBlacklisted(collector));
        assertFalse(registry.isEligibleCollector(collector));
    }

    function testFuzz_blacklistCollector_unauthorizedReverts(address caller) public {
        vm.assume(caller != kycAdmin);
        vm.assume(!registry.hasRole(kycAdminRole, caller));

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, caller, kycAdminRole
        ));
        vm.prank(caller);
        registry.blacklistCollector(alice);
    }

    function testFuzz_blacklistedRegisteredIsNeverEligible(address collector) public {
        vm.assume(collector != address(0));

        vm.prank(collector);
        registry.registerCollector("QmFuzzProfile");

        vm.prank(kycAdmin);
        registry.blacklistCollector(collector);

        assertFalse(registry.isEligibleCollector(collector));
    }

    function test_stateMachine_fullNegativeLifecycle() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");
        assertTrue(registry.isEligibleCollector(alice),   "should be eligible after register");
        assertTrue(registry.isRegisteredCollector(alice), "should be registered");

        vm.prank(kycAdmin);
        registry.blacklistCollector(alice);
        assertFalse(registry.isEligibleCollector(alice),  "should be ineligible after blacklist");
        assertTrue(registry.isRegisteredCollector(alice), "still registered");
        assertTrue(registry.isBlacklisted(alice),         "should be blacklisted");
    }

    // 11. NEGATIVE ACCESS CONTROL TESTS
    function test_ac_randomAddressCannotBlacklist() public {
        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, kycAdminRole
        ));
        vm.prank(attacker);
        registry.blacklistCollector(alice);
    }

    function test_ac_randomAddressCannotIncrementProjectCount() public {
        vm.prank(alice);
        registry.registerCollector("QmAlice");

        vm.expectRevert(abi.encodeWithSelector(
            IAccessControl.AccessControlUnauthorizedAccount.selector, attacker, poolRole
        ));
        vm.prank(attacker);
        registry.incrementProjectCount(alice);
    }
}
