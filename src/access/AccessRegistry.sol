pragma solidity 0.8.24;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";

contract AccessRegistry is AccessControl, IAccessRegistry {

    error AccessRegistry__ZeroAddress();
    error AccessRegistry__AlreadyBlacklisted(address collector);
    error AccessRegistry__AlreadyRegistered(address collector);
    error AccessRegistry__ProfileNotFound(address collector);
    error AccessRegistry__EmptyURI();
    error AccessRegistry__Unauthorized();
    error AccessRegistry__Blacklisted(address collector);

    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");
    bytes32 public constant OPERATOR_ROLE  = keccak256("OPERATOR_ROLE");
    bytes32 public constant POOL_ROLE      = keccak256("POOL_ROLE");

    string  public baseProfileURI = "https://gateway.pinata.cloud/ipfs/";
    mapping(address => bool)             public isBlacklisted;
    mapping(address => CollectorProfile) public collectorProfiles;

    constructor(address admin) {
        if (admin == address(0)) revert AccessRegistry__ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
    }

    function registerCollector(string calldata cid) external {
        if (isBlacklisted[msg.sender])            revert AccessRegistry__Blacklisted(msg.sender);
        if (collectorProfiles[msg.sender].exists) revert AccessRegistry__AlreadyRegistered(msg.sender);
        if (bytes(cid).length == 0)               revert AccessRegistry__EmptyURI();

        string memory uri = string(abi.encodePacked(baseProfileURI, cid));

        collectorProfiles[msg.sender] = CollectorProfile({
            profileURI:        uri,
            totalProjects:     0,
            completedProjects: 0,
            defaultedProjects: 0,
            registeredAt:      block.timestamp,
            exists:            true
        });

        emit CollectorRegistered(msg.sender, uri);
    }

    function updateCollectorProfile(string calldata newCid) external {
        if (!collectorProfiles[msg.sender].exists) revert AccessRegistry__ProfileNotFound(msg.sender);
        if (bytes(newCid).length == 0)             revert AccessRegistry__EmptyURI();

        string memory uri = string(abi.encodePacked(baseProfileURI, newCid));
        collectorProfiles[msg.sender].profileURI = uri;
        emit CollectorProfileUpdated(msg.sender, uri);
    }

    function setBaseProfileURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseProfileURI = newBaseURI;
    }

    function blacklistCollector(address collector) external onlyRole(KYC_ADMIN_ROLE) {
        if (collector == address(0))  revert AccessRegistry__ZeroAddress();
        if (isBlacklisted[collector]) revert AccessRegistry__AlreadyBlacklisted(collector);

        isBlacklisted[collector] = true;
        emit CollectorBlacklisted(collector);
    }

    function incrementProjectCount(address collector) external onlyRole(POOL_ROLE) {
        if (!collectorProfiles[collector].exists) return;

        CollectorProfile storage profile = collectorProfiles[collector];
        profile.totalProjects++;
        emit CollectorReputationUpdated(collector, profile.totalProjects, profile.completedProjects, profile.defaultedProjects);
    }

    function incrementCompletedCount(address collector) external onlyRole(POOL_ROLE) {
        if (!collectorProfiles[collector].exists) return;

        CollectorProfile storage profile = collectorProfiles[collector];
        profile.completedProjects++;
        emit CollectorReputationUpdated(collector, profile.totalProjects, profile.completedProjects, profile.defaultedProjects);
    }

    function incrementDefaultedCount(address collector) external onlyRole(POOL_ROLE) {
        if (!collectorProfiles[collector].exists) return;

        CollectorProfile storage profile = collectorProfiles[collector];
        profile.defaultedProjects++;
        emit CollectorReputationUpdated(collector, profile.totalProjects, profile.completedProjects, profile.defaultedProjects);
    }

    function isRegisteredCollector(address collector) external view returns (bool) {
        return collectorProfiles[collector].exists;
    }

    function isEligibleCollector(address collector) external view returns (bool eligible) {
        eligible = collectorProfiles[collector].exists && !isBlacklisted[collector];
    }

    function getCollectorProfile(address collector)
        external
        view
        returns (CollectorProfile memory)
    {
        return collectorProfiles[collector];
    }
}
