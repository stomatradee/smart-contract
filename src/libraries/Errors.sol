pragma solidity 0.8.24;

import {DataTypes} from "./DataTypes.sol";

library Errors {

    error AccessControl__NotAdmin();
    error AccessControl__NotVerifier();
    error AccessControl__NotProjectCollector(uint256 projectId, address caller);
    error AccessControl__NotTreasury();

    error Project__NotFound(uint256 projectId);
    error Project__InvalidStatus(
        uint256 projectId,
        DataTypes.ProjectStatus current,
        DataTypes.ProjectStatus required
    );
    error Project__CollateralNotVerified(uint256 projectId);
    error Project__FundingDeadlineExpired(uint256 projectId, uint256 deadline);
    error Project__GracePeriodNotElapsed(uint256 projectId, uint256 deadline);
    error Project__FundingCapReached(uint256 projectId, uint256 maxFunding, uint256 funded);
    error Project__DeadlineTooShort(uint256 provided, uint256 minimum);
    error Project__RepaymentBeforeFunding(uint256 fundingDeadline, uint256 repaymentDeadline);
    error Project__ZeroCollateralValue();
    error Project__ZeroVolumeKg();
    error Project__ZeroProfitPerKg();

    error Investment__ZeroAmount();
    error Investment__ExceedsRemainingCapacity(uint256 requested, uint256 remaining);
    error Investment__AlreadyInvested(uint256 projectId, address investor);
    error Investment__NotFound(uint256 projectId, address investor);

    error Claim__AlreadyClaimed(uint256 projectId, address investor);
    error Claim__DistributionNotDone(uint256 projectId);
    error Distribution__AlreadyDistributed(uint256 projectId);
    error Distribution__InsufficientBuyerPayment(uint256 received, uint256 required);

    error Token__NotWhitelisted(address token);
    error Token__TransferFailed(address token, address from, address to, uint256 amount);

    error ZeroAddress();
    error ZeroValue();
    error ArrayLengthMismatch(uint256 lengthA, uint256 lengthB);
}
