pragma solidity 0.8.24;

interface IAccessRegistry {
    struct CollectorProfile {
        string  profileURI;
        uint256 totalProjects;
        uint256 completedProjects;
        uint256 defaultedProjects;
        uint256 registeredAt;
        bool    exists;
    }

    event CollectorBlacklisted(address indexed collector);
    event CollectorRegistered(address indexed collector, string profileURI);
    event CollectorProfileUpdated(address indexed collector, string newProfileURI);
    event CollectorReputationUpdated(
        address indexed collector,
        uint256 totalProjects,
        uint256 completedProjects,
        uint256 defaultedProjects
    );

    function KYC_ADMIN_ROLE() external view returns (bytes32);
    function OPERATOR_ROLE()  external view returns (bytes32);
    function POOL_ROLE()      external view returns (bytes32);

    function registerCollector(string calldata cid) external;
    function updateCollectorProfile(string calldata newCid) external;
    function setBaseProfileURI(string calldata newBaseURI) external;
    function blacklistCollector(address collector) external;
    function incrementProjectCount(address collector) external;
    function incrementCompletedCount(address collector) external;
    function incrementDefaultedCount(address collector) external;

    function baseProfileURI()                         external view returns (string memory);
    function isRegisteredCollector(address collector) external view returns (bool);
    function isBlacklisted(address collector)         external view returns (bool);
    function isEligibleCollector(address collector)   external view returns (bool eligible);
    function getCollectorProfile(address collector)   external view returns (CollectorProfile memory);

    function collectorProfiles(address collector)
        external
        view
        returns (
            string memory profileURI,
            uint256 totalProjects,
            uint256 completedProjects,
            uint256 defaultedProjects,
            uint256 registeredAt,
            bool    exists
        );
}
