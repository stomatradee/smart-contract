pragma solidity 0.8.24;

library Events {
   
    event ProjectCreated(
        uint256 indexed projectId,
        address indexed collector,
        address indexed acceptedToken,
        string  commodityType,
        uint256 volumeKg,
        uint256 maxFunding
    );

    event CollateralVerified(
        uint256 indexed projectId,
        bool    verified,
        address indexed verifier
    );

    event ProjectOpened(uint256 indexed projectId, uint256 fundingDeadline);
    event ProjectFunded(uint256 indexed projectId, uint256 totalFunded);

    event ProjectClosed(
        uint256 indexed projectId,
        address indexed collector,
        uint256 totalFunded
    );

    event FundsDisbursed(
        uint256 indexed projectId,
        address indexed collector,
        uint256 amount
    );

    event BuyerPaymentReceived(
        uint256 indexed projectId,
        address indexed buyer,
        uint256 amount
    );

    event ProceedsDistributed(
        uint256 indexed projectId,
        uint256 totalInvestorReturn,
        uint256 platformFee,
        uint256 collectorRemainder
    );

    event ProjectDefaulted(
        uint256 indexed projectId,
        uint256 repaymentDeadline,
        address indexed triggeredBy
    );

    event ProjectCompleted(uint256 indexed projectId);

    event Invested(
        uint256 indexed projectId,
        address indexed investor,
        uint256 amount,
        uint256 totalFunded
    );

    event InvestorClaimed(
        uint256 indexed projectId,
        address indexed investor,
        uint256 principal,
        uint256 profit
    );

    event CollectorClaimed(
        uint256 indexed projectId,
        address indexed collector,
        uint256 amount
    );

    event PlatformFeeClaimed(
        uint256 indexed projectId,
        address indexed treasury,
        uint256 amount
    );

    event TreasuryUpdated(address indexed oldTreasury, address indexed newTreasury);
    event TokenWhitelistUpdated(address indexed token, bool whitelisted);
    event LtvRatioUpdated(uint256 oldLtv, uint256 newLtv);
    event GracePeriodUpdated(uint256 oldGracePeriod, uint256 newGracePeriod);
}
