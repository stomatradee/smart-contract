pragma solidity 0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IProjectManager {
    struct CreateProjectParams {
        address acceptedToken;
        string  commodityType;
        uint256 volumeKg;
        uint256 collateralValue;
        uint256 profitPerKgInvestor;
        uint256 profitPerKgPlatform;
        uint256 fundingDeadline;
        uint256 repaymentDeadline;
        string  metadataURI;
    }

    function createProject(CreateProjectParams calldata params) external returns (uint256 projectId);
    function closeFunding(uint256 projectId) external;
    function setCollateralVerified(uint256 projectId, bool verified) external;
    function triggerDefault(uint256 projectId) external;

    function getProject(uint256 projectId) external view returns (DataTypes.Project memory project);
    function projectCount() external view returns (uint256);
    function getDistribution(uint256 projectId) external view returns (DataTypes.Distribution memory distribution);
}
