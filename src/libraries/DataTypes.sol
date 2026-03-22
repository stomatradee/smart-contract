pragma solidity 0.8.24;

library DataTypes {

    enum ProjectStatus {
        PENDING_VERIFICATION,
        OPEN,
        FUNDED,
        CLOSED,
        DISBURSED,
        SETTLED,
        DEFAULTED,
        COMPLETED,
        REJECTED
    }

    struct Project {
        address collector;
        address acceptedToken;
        string  commodityType;
        uint256 volumeKg;
        uint256 collateralValue;
        uint256 maxFunding;
        uint256 totalFunded;
        uint256 fundingDeadline;
        uint256 repaymentDuration;
        uint256 repaymentDeadline;
        uint256 buyerPaymentAmount;
        bool    collateralVerified;
        ProjectStatus status;
        string  metadataURI;
    }

    struct Investment {
        address investor;
        bool    claimed;
        uint256 amount;
        uint256 timestamp;
    }

    struct Distribution {
        uint256 investorFunds;
        uint256 platformFee;
        uint256 collectorFunds;
        uint256 claimedInvestorCount;
        bool    finalized;
        bool    collectorWithdrawn;
    }
}
