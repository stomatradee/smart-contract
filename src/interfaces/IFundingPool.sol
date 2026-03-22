pragma solidity 0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

interface IFundingPool {
    function invest(uint256 projectId, uint256 amount) external;

    function disburse(uint256 projectId) external;

    function getInvestment(uint256 projectId, address investor)
        external
        view
        returns (DataTypes.Investment memory investment);

    function getInvestors(uint256 projectId)
        external
        view
        returns (address[] memory investors);

    function remainingCapacity(uint256 projectId)
        external
        view
        returns (uint256 remaining);
}
