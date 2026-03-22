pragma solidity 0.8.24;

import {ERC721}          from "@openzeppelin/contracts/token/ERC721/ERC721.sol";
import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {IProjectNFT}     from "../interfaces/IProjectNFT.sol";
import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";
import {DataTypes}       from "../libraries/DataTypes.sol";

contract ProjectNFT is ERC721, AccessControl, IProjectNFT {

    error ProjectNFT__ZeroAddress();
    error ProjectNFT__NotRegisteredCollector(address caller);
    error ProjectNFT__CollectorBlacklisted(address caller);
    error ProjectNFT__ZeroValue();
    error ProjectNFT__InvalidFundingDuration();
    error ProjectNFT__ProjectNotFound(uint256 projectId);
    error ProjectNFT__InvalidStatus(uint256 projectId, DataTypes.ProjectStatus current);

    bytes32 public constant KYC_ADMIN_ROLE = keccak256("KYC_ADMIN_ROLE");
    bytes32 public constant POOL_ROLE      = keccak256("POOL_ROLE");

    uint256 public constant  LTV_RATIO            = 7500;
    uint256 private constant BASIS_POINTS         = 10_000;
    uint256 private constant MIN_FUNDING_DURATION = 1 hours;

    IAccessRegistry public immutable accessRegistry;

    string  public baseTokenURI = "https://gateway.pinata.cloud/ipfs/";
    uint256 public projectCount;
    mapping(uint256 => ProjectData) private _projects;

    constructor(address admin, address accessRegistry_) ERC721("StomaTrace Project", "STMP") {
        if (admin           == address(0)) revert ProjectNFT__ZeroAddress();
        if (accessRegistry_ == address(0)) revert ProjectNFT__ZeroAddress();
        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        accessRegistry = IAccessRegistry(accessRegistry_);
    }

    function mintProject(
        address acceptedToken,
        string  calldata commodityType,
        uint256 volumeKg,
        uint256 collateralValue,
        uint256 fundingDuration,
        uint256 repaymentDuration,
        string  calldata cid
    ) external returns (uint256 projectId) {
        if (!accessRegistry.isRegisteredCollector(msg.sender)) {
            revert ProjectNFT__NotRegisteredCollector(msg.sender);
        }
        if (accessRegistry.isBlacklisted(msg.sender)) {
            revert ProjectNFT__CollectorBlacklisted(msg.sender);
        }
        if (volumeKg == 0 || collateralValue == 0) revert ProjectNFT__ZeroValue();
        if (repaymentDuration == 0)                revert ProjectNFT__ZeroValue();
        if (fundingDuration < MIN_FUNDING_DURATION) revert ProjectNFT__InvalidFundingDuration();

        projectId = ++projectCount;
        uint256 maxFunding = (collateralValue * LTV_RATIO) / BASIS_POINTS;

        string memory uri = bytes(cid).length > 0
            ? string(abi.encodePacked(baseTokenURI, cid))
            : "";

        _projects[projectId] = ProjectData({
            collector:          msg.sender,
            acceptedToken:      acceptedToken,
            commodityType:      commodityType,
            volumeKg:           volumeKg,
            collateralValue:    collateralValue,
            maxFunding:         maxFunding,
            fundingDeadline:    block.timestamp + fundingDuration,
            repaymentDuration:  repaymentDuration,
            metadataURI:        uri,
            collateralVerified: false,
            status:             DataTypes.ProjectStatus.PENDING_VERIFICATION
        });

        _mint(msg.sender, projectId);
        emit ProjectMinted(projectId, msg.sender, acceptedToken, volumeKg, maxFunding);

        accessRegistry.incrementProjectCount(msg.sender);
    }

    function setBaseTokenURI(string calldata newBaseURI) external onlyRole(DEFAULT_ADMIN_ROLE) {
        baseTokenURI = newBaseURI;
    }

    function verifyProject(uint256 projectId) external onlyRole(KYC_ADMIN_ROLE) {
        ProjectData storage project = _requireProject(projectId);
        if (project.status != DataTypes.ProjectStatus.PENDING_VERIFICATION) {
            revert ProjectNFT__InvalidStatus(projectId, project.status);
        }

        project.collateralVerified = true;
        project.status = DataTypes.ProjectStatus.OPEN;
        emit ProjectVerified(projectId, msg.sender);
    }

    function rejectProject(uint256 projectId) external onlyRole(KYC_ADMIN_ROLE) {
        ProjectData storage project = _requireProject(projectId);
        if (project.status != DataTypes.ProjectStatus.PENDING_VERIFICATION) {
            revert ProjectNFT__InvalidStatus(projectId, project.status);
        }

        project.status = DataTypes.ProjectStatus.REJECTED;
        emit ProjectRejected(projectId);
    }

    function updateStatus(uint256 projectId, DataTypes.ProjectStatus newStatus)
        external
        onlyRole(POOL_ROLE)
    {
        _requireProject(projectId).status = newStatus;
        emit ProjectStatusUpdated(projectId, newStatus);
    }

    function getProject(uint256 projectId) external view returns (ProjectData memory) {
        _requireProjectView(projectId);
        return _projects[projectId];
    }

    function ownerOf(uint256 tokenId)
        public
        view
        override(ERC721, IProjectNFT)
        returns (address)
    {
        return super.ownerOf(tokenId);
    }

    function supportsInterface(bytes4 interfaceId)
        public
        view
        override(ERC721, AccessControl)
        returns (bool)
    {
        return super.supportsInterface(interfaceId);
    }

    function _requireProject(uint256 projectId) internal view returns (ProjectData storage) {
        if (projectId == 0 || projectId > projectCount) {
            revert ProjectNFT__ProjectNotFound(projectId);
        }
        return _projects[projectId];
    }

    function _requireProjectView(uint256 projectId) internal view {
        if (projectId == 0 || projectId > projectCount) {
            revert ProjectNFT__ProjectNotFound(projectId);
        }
    }

    function tokenURI(uint256 tokenId) public view override returns (string memory) {
        _requireOwned(tokenId);
        return _projects[tokenId].metadataURI;
    }
}
