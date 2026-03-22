pragma solidity 0.8.24;

import {DataTypes} from "../libraries/DataTypes.sol";

interface ILendingPool {
    event Invested(
        uint256 indexed projectId,
        address indexed investor,
        uint256 amount,
        uint256 totalFunded
    );
    event ProjectAutoFunded(uint256 indexed projectId, uint256 totalFunded);
    event ProjectManuallyClosed(
        uint256 indexed projectId,
        address indexed collector,
        uint256 totalFunded
    );
    event FundsDisbursed(
        uint256 indexed projectId,
        address indexed collector,
        uint256 amount,
        uint256 repaymentDeadline
    );
    event BuyerPaymentRecorded(uint256 indexed projectId, uint256 amount);
    event ProfitDistributed(
        uint256 indexed projectId,
        uint256 investorFunds,
        uint256 platformFee,
        uint256 collectorFunds
    );
    event InvestorFundsClaimed(uint256 indexed projectId, address indexed investor, uint256 amount);
    event CollectorFundsClaimed(uint256 indexed projectId, address indexed collector, uint256 amount);
    event ProjectDefaulted(uint256 indexed projectId);
    event ProjectCompleted(uint256 indexed projectId);
    event AcceptedTokenSet(address indexed token, bool accepted);
    event PlatformWalletSet(address indexed newWallet);

    function closeFunding(uint256 projectId) external;
    function invest(uint256 projectId, uint256 amount) external;
    function disburseFunds(uint256 projectId) external;
    function recordBuyerPayment(uint256 projectId, uint256 amount) external;
    function claimInvestorFunds(uint256 projectId) external;
    function claimCollectorFunds(uint256 projectId) external;
    function markDefaulted(uint256 projectId) external;
    function setAcceptedToken(address token, bool accepted) external;
    function setPlatformWallet(address newWallet) external;

    function getProject(uint256 projectId)      external view returns (DataTypes.Project memory);
    function getInvestments(uint256 projectId)  external view returns (DataTypes.Investment[] memory);
    function getInvestment(uint256 projectId, address investor) external view returns (DataTypes.Investment memory);
    function getDistribution(uint256 projectId) external view returns (DataTypes.Distribution memory);
    function projectCount()           external view returns (uint256);
    function LTV_RATIO()              external view returns (uint256);
    function GRACE_PERIOD()           external view returns (uint256);
    function PROFIT_PER_KG_INVESTOR() external view returns (uint256);
    function PROFIT_PER_KG_PLATFORM() external view returns (uint256);
}
