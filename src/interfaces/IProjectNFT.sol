pragma solidity 0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IProjectNFT {
    struct ProjectData {
        address collector;
        address acceptedToken;
        string  commodityType;
        uint256 volumeKg;
        uint256 collateralValue;
        uint256 maxFunding;
        uint256 fundingDeadline;
        uint256 repaymentDuration;
        string  metadataURI;
        bool    collateralVerified;
        DataTypes.ProjectStatus status;
    }

    event ProjectMinted(
        uint256 indexed projectId,
        address indexed collector,
        address indexed acceptedToken,
        uint256 volumeKg,
        uint256 maxFunding
    );
    event ProjectVerified(uint256 indexed projectId, address indexed verifier);
    event ProjectRejected(uint256 indexed projectId);
    event ProjectStatusUpdated(uint256 indexed projectId, DataTypes.ProjectStatus newStatus);

    function KYC_ADMIN_ROLE() external view returns (bytes32);
    function POOL_ROLE()      external view returns (bytes32);

    function mintProject(
        address acceptedToken,
        string  calldata commodityType,
        uint256 volumeKg,
        uint256 collateralValue,
        uint256 fundingDuration,
        uint256 repaymentDuration,
        string  calldata cid
    ) external returns (uint256 projectId);

    function verifyProject(uint256 projectId) external;
    function rejectProject(uint256 projectId) external;
    function updateStatus(uint256 projectId, DataTypes.ProjectStatus newStatus) external;
    function setBaseTokenURI(string calldata newBaseURI) external;

    function getProject(uint256 projectId) external view returns (ProjectData memory);
    function ownerOf(uint256 tokenId)      external view returns (address owner);
    function projectCount()                external view returns (uint256);
    function baseTokenURI()                external view returns (string memory);
}
