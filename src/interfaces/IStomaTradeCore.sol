pragma solidity 0.8.24;

import {IProjectManager}  from "./IProjectManager.sol";
import {IFundingPool}     from "./IFundingPool.sol";
import {IRepaymentManager} from "./IRepaymentManager.sol";
import {ITokenWhitelist}  from "./ITokenWhitelist.sol";

interface IStomaTradeCore is
    IProjectManager,
    IFundingPool,
    IRepaymentManager,
    ITokenWhitelist
{
    function setTreasury(address newTreasury) external;
    function setLtvRatio(uint256 newLtvBps) external;
    function setGracePeriod(uint256 newGracePeriod) external;

    function treasury()     external view returns (address);
    function ltvRatio()     external view returns (uint256);
    function gracePeriod()  external view returns (uint256);
}
