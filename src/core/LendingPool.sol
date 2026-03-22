pragma solidity 0.8.24;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {Pausable}        from "@openzeppelin/contracts/utils/Pausable.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";

import {ILendingPool}    from "../interfaces/ILendingPool.sol";
import {IProjectNFT}     from "../interfaces/IProjectNFT.sol";
import {ITreasury}       from "../interfaces/ITreasury.sol";
import {IAccessRegistry} from "../interfaces/IAccessRegistry.sol";
import {DataTypes}       from "../libraries/DataTypes.sol";

contract LendingPool is AccessControl, ReentrancyGuard, Pausable, ILendingPool {
    using SafeERC20 for IERC20;

    error LendingPool__ZeroAddress();
    error LendingPool__ZeroValue();
    error LendingPool__TokenNotAccepted(address token);
    error LendingPool__ProjectNotFound(uint256 projectId);
    error LendingPool__InvalidStatus(uint256 projectId, DataTypes.ProjectStatus current, string required);
    error LendingPool__FundingDeadlineExpired(uint256 projectId, uint256 deadline);
    error LendingPool__ExceedsCapacity(uint256 requested, uint256 remaining);
    error LendingPool__AlreadyInvested(uint256 projectId, address investor);
    error LendingPool__NotInvestor(uint256 projectId, address investor);
    error LendingPool__AlreadyClaimed(uint256 projectId, address investor);
    error LendingPool__NotDistributed(uint256 projectId);
    error LendingPool__NotProjectOwner(uint256 projectId, address caller);
    error LendingPool__NoFundsToClose(uint256 projectId);
    error LendingPool__NoRemainderToClaim(uint256 projectId);
    error LendingPool__RemainderAlreadyClaimed(uint256 projectId);
    error LendingPool__GracePeriodNotElapsed(uint256 projectId, uint256 gracePeriodEnd);

    bytes32 public constant OPERATOR_ROLE = keccak256("OPERATOR_ROLE");

    uint256 public constant LTV_RATIO             = 7500;
    uint256 public constant GRACE_PERIOD          = 7 days;
    uint256 public constant PROFIT_PER_KG_INVESTOR = 50;
    uint256 public constant PROFIT_PER_KG_PLATFORM = 150;

    IProjectNFT     public projectNft;
    ITreasury       public treasury;
    IAccessRegistry public accessRegistry;
    address         public platformWallet;

    struct LendingState {
        uint256 totalFunded;
        uint256 repaymentDeadline;
        uint256 buyerPaymentAmount;
    }

    mapping(uint256 => LendingState)                        private _lendingState;
    mapping(uint256 => DataTypes.Investment[])              private _investments;
    mapping(uint256 => mapping(address => uint256))         private _investorIndex;
    mapping(uint256 => DataTypes.Distribution)              private _distributions;
    mapping(address => bool)                                public  acceptedTokens;

    constructor(
        address admin_,
        address projectNft_,
        address treasury_,
        address accessRegistry_,
        address platformWallet_
    ) {
        if (admin_ == address(0))          revert LendingPool__ZeroAddress();
        if (projectNft_ == address(0))     revert LendingPool__ZeroAddress();
        if (treasury_ == address(0))       revert LendingPool__ZeroAddress();
        if (accessRegistry_ == address(0)) revert LendingPool__ZeroAddress();
        if (platformWallet_ == address(0)) revert LendingPool__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin_);
        projectNft     = IProjectNFT(projectNft_);
        treasury       = ITreasury(treasury_);
        accessRegistry = IAccessRegistry(accessRegistry_);
        platformWallet = platformWallet_;
    }

    function closeFunding(uint256 projectId) external {
        IProjectNFT.ProjectData memory pd = _requireProject(projectId);
        _requireOwner(projectId);

        if (pd.status != DataTypes.ProjectStatus.OPEN) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "OPEN");
        }
        if (_lendingState[projectId].totalFunded == 0) revert LendingPool__NoFundsToClose(projectId);

        projectNft.updateStatus(projectId, DataTypes.ProjectStatus.CLOSED);
        emit ProjectManuallyClosed(projectId, msg.sender, _lendingState[projectId].totalFunded);
    }

    function claimCollectorFunds(uint256 projectId) external nonReentrant {
        IProjectNFT.ProjectData memory pd = _requireProject(projectId);
        _requireOwner(projectId);

        if (pd.status != DataTypes.ProjectStatus.SETTLED) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "SETTLED");
        }

        DataTypes.Distribution storage dist = _distributions[projectId];
        if (!dist.finalized)            revert LendingPool__NotDistributed(projectId);
        if (dist.collectorFunds == 0) revert LendingPool__NoRemainderToClaim(projectId);
        if (dist.collectorWithdrawn)        revert LendingPool__RemainderAlreadyClaimed(projectId);

        uint256 amount = dist.collectorFunds;
        dist.collectorWithdrawn = true;

        treasury.release(projectId, pd.acceptedToken, amount, msg.sender);
        emit CollectorFundsClaimed(projectId, msg.sender, amount);

        _checkAndMarkCompleted(projectId, pd.collector, dist);
    }

    function invest(uint256 projectId, uint256 amount)
        external
        nonReentrant
        whenNotPaused
    {
        if (amount == 0) revert LendingPool__ZeroValue();

        IProjectNFT.ProjectData memory pd = _requireProject(projectId);

        if (pd.status != DataTypes.ProjectStatus.OPEN) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "OPEN");
        }
        if (!acceptedTokens[pd.acceptedToken]) {
            revert LendingPool__TokenNotAccepted(pd.acceptedToken);
        }
        if (block.timestamp >= pd.fundingDeadline) {
            revert LendingPool__FundingDeadlineExpired(projectId, pd.fundingDeadline);
        }
        if (_investorIndex[projectId][msg.sender] != 0) {
            revert LendingPool__AlreadyInvested(projectId, msg.sender);
        }

        LendingState storage ls = _lendingState[projectId];
        uint256 remaining = pd.maxFunding - ls.totalFunded;
        if (amount > remaining) revert LendingPool__ExceedsCapacity(amount, remaining);

        ls.totalFunded += amount;
        _investments[projectId].push(DataTypes.Investment({
            investor:  msg.sender,
            claimed:   false,
            amount:    amount,
            timestamp: block.timestamp
        }));
        _investorIndex[projectId][msg.sender] = _investments[projectId].length;

        emit Invested(projectId, msg.sender, amount, ls.totalFunded);

        if (ls.totalFunded == pd.maxFunding) {
            projectNft.updateStatus(projectId, DataTypes.ProjectStatus.FUNDED);
            emit ProjectAutoFunded(projectId, ls.totalFunded);
        }

        IERC20(pd.acceptedToken).safeTransferFrom(msg.sender, address(treasury), amount);
        treasury.deposit(projectId, pd.acceptedToken, amount, msg.sender);
    }

    function claimInvestorFunds(uint256 projectId) external nonReentrant {
        IProjectNFT.ProjectData memory pd = _requireProject(projectId);

        if (pd.status != DataTypes.ProjectStatus.SETTLED) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "SETTLED");
        }

        DataTypes.Distribution storage dist = _distributions[projectId];
        if (!dist.finalized) revert LendingPool__NotDistributed(projectId);

        uint256 idx = _investorIndex[projectId][msg.sender];
        if (idx == 0) revert LendingPool__NotInvestor(projectId, msg.sender);

        DataTypes.Investment storage inv = _investments[projectId][idx - 1];
        if (inv.claimed) revert LendingPool__AlreadyClaimed(projectId, msg.sender);

        uint256 myReturn = (dist.investorFunds * inv.amount) / _lendingState[projectId].totalFunded;
        inv.claimed = true;
        dist.claimedInvestorCount++;

        if (myReturn > 0) {
            treasury.release(projectId, pd.acceptedToken, myReturn, msg.sender);
        }
        emit InvestorFundsClaimed(projectId, msg.sender, myReturn);

        _checkAndMarkCompleted(projectId, pd.collector, dist);
    }

    function disburseFunds(uint256 projectId)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        IProjectNFT.ProjectData memory pd = _requireProject(projectId);

        if (
            pd.status != DataTypes.ProjectStatus.FUNDED &&
            pd.status != DataTypes.ProjectStatus.CLOSED
        ) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "FUNDED or CLOSED");
        }

        LendingState storage ls = _lendingState[projectId];
        uint256 amount = ls.totalFunded;
        ls.repaymentDeadline = block.timestamp + pd.repaymentDuration;

        projectNft.updateStatus(projectId, DataTypes.ProjectStatus.DISBURSED);
        emit FundsDisbursed(projectId, pd.collector, amount, ls.repaymentDeadline);

        treasury.release(projectId, pd.acceptedToken, amount, pd.collector);
    }

    function recordBuyerPayment(uint256 projectId, uint256 amount)
        external
        onlyRole(OPERATOR_ROLE)
        nonReentrant
    {
        if (amount == 0) revert LendingPool__ZeroValue();

        IProjectNFT.ProjectData memory pd = _requireProject(projectId);

        if (pd.status != DataTypes.ProjectStatus.DISBURSED) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "DISBURSED");
        }

        uint256 totalFunded              = _lendingState[projectId].totalFunded;
        uint256 theoreticalInvestorReturn = totalFunded + (pd.volumeKg * PROFIT_PER_KG_INVESTOR);
        uint256 theoreticalPlatformFee    = pd.volumeKg * PROFIT_PER_KG_PLATFORM;
        uint256 fullRequired              = theoreticalInvestorReturn + theoreticalPlatformFee;

        uint256 actualInvestorReturn;
        uint256 actualPlatformFee;
        uint256 collectorFunds;

        if (amount >= fullRequired) {
            actualInvestorReturn = theoreticalInvestorReturn;
            actualPlatformFee    = theoreticalPlatformFee;
            collectorFunds   = amount - fullRequired;
        } else if (amount >= theoreticalInvestorReturn) {
            actualInvestorReturn = theoreticalInvestorReturn;
            actualPlatformFee    = amount - theoreticalInvestorReturn;
            collectorFunds   = 0;
        } else {
            actualInvestorReturn = amount;
            actualPlatformFee    = 0;
            collectorFunds   = 0;
        }

        _lendingState[projectId].buyerPaymentAmount = amount;
        projectNft.updateStatus(projectId, DataTypes.ProjectStatus.SETTLED);

        DataTypes.Distribution storage dist = _distributions[projectId];
        dist.investorFunds = actualInvestorReturn;
        dist.platformFee         = actualPlatformFee;
        dist.collectorFunds  = collectorFunds;
        dist.finalized         = true;

        if (collectorFunds == 0) dist.collectorWithdrawn = true;

        emit BuyerPaymentRecorded(projectId, amount);
        emit ProfitDistributed(projectId, actualInvestorReturn, actualPlatformFee, collectorFunds);

        IERC20(pd.acceptedToken).safeTransferFrom(msg.sender, address(treasury), amount);
        treasury.deposit(projectId, pd.acceptedToken, amount, msg.sender);

        if (actualPlatformFee > 0) {
            treasury.release(projectId, pd.acceptedToken, actualPlatformFee, platformWallet);
        }

        _checkAndMarkCompleted(projectId, pd.collector, dist);
    }

    function markDefaulted(uint256 projectId) external onlyRole(OPERATOR_ROLE) {
        IProjectNFT.ProjectData memory pd = _requireProject(projectId);

        if (pd.status != DataTypes.ProjectStatus.DISBURSED) {
            revert LendingPool__InvalidStatus(projectId, pd.status, "DISBURSED");
        }

        uint256 gracePeriodEnd = _lendingState[projectId].repaymentDeadline + GRACE_PERIOD;
        if (block.timestamp <= gracePeriodEnd) {
            revert LendingPool__GracePeriodNotElapsed(projectId, gracePeriodEnd);
        }

        projectNft.updateStatus(projectId, DataTypes.ProjectStatus.DEFAULTED);
        emit ProjectDefaulted(projectId);
        accessRegistry.incrementDefaultedCount(pd.collector);
    }

    function setAcceptedToken(address token, bool accepted)
        external
        onlyRole(DEFAULT_ADMIN_ROLE)
    {
        if (token == address(0)) revert LendingPool__ZeroAddress();
        acceptedTokens[token] = accepted;
        emit AcceptedTokenSet(token, accepted);
    }

    function setPlatformWallet(address newWallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (newWallet == address(0)) revert LendingPool__ZeroAddress();
        platformWallet = newWallet;
        emit PlatformWalletSet(newWallet);
    }

    function pause()   external onlyRole(OPERATOR_ROLE)     { _pause(); }
    function unpause() external onlyRole(DEFAULT_ADMIN_ROLE) { _unpause(); }

    function getProject(uint256 projectId) external view returns (DataTypes.Project memory) {
        _requireProjectView(projectId);
        IProjectNFT.ProjectData memory pd = projectNft.getProject(projectId);
        LendingState memory ls = _lendingState[projectId];
        return DataTypes.Project({
            collector:           pd.collector,
            acceptedToken:       pd.acceptedToken,
            commodityType:       pd.commodityType,
            volumeKg:            pd.volumeKg,
            collateralValue:     pd.collateralValue,
            maxFunding:          pd.maxFunding,
            totalFunded:         ls.totalFunded,
            fundingDeadline:     pd.fundingDeadline,
            repaymentDuration:   pd.repaymentDuration,
            repaymentDeadline:   ls.repaymentDeadline,
            buyerPaymentAmount:  ls.buyerPaymentAmount,
            collateralVerified:  pd.collateralVerified,
            status:              pd.status,
            metadataURI:         pd.metadataURI
        });
    }

    function getInvestments(uint256 projectId) external view returns (DataTypes.Investment[] memory) {
        _requireProjectView(projectId);
        return _investments[projectId];
    }

    function getInvestment(uint256 projectId, address investor)
        external
        view
        returns (DataTypes.Investment memory)
    {
        uint256 idx = _investorIndex[projectId][investor];
        if (idx == 0) revert LendingPool__NotInvestor(projectId, investor);
        return _investments[projectId][idx - 1];
    }

    function getDistribution(uint256 projectId) external view returns (DataTypes.Distribution memory) {
        return _distributions[projectId];
    }

    function projectCount() external view returns (uint256) {
        return projectNft.projectCount();
    }

    function _requireProject(uint256 projectId)
        internal
        view
        returns (IProjectNFT.ProjectData memory)
    {
        if (projectId == 0 || projectId > projectNft.projectCount()) {
            revert LendingPool__ProjectNotFound(projectId);
        }
        return projectNft.getProject(projectId);
    }

    function _requireProjectView(uint256 projectId) internal view {
        if (projectId == 0 || projectId > projectNft.projectCount()) {
            revert LendingPool__ProjectNotFound(projectId);
        }
    }

    function _requireOwner(uint256 projectId) internal view {
        if (projectNft.ownerOf(projectId) != msg.sender) {
            revert LendingPool__NotProjectOwner(projectId, msg.sender);
        }
    }

    function _checkAndMarkCompleted(
        uint256 projectId,
        address collector,
        DataTypes.Distribution storage dist
    ) internal {
        if (dist.collectorWithdrawn && dist.claimedInvestorCount == _investments[projectId].length) {
            projectNft.updateStatus(projectId, DataTypes.ProjectStatus.COMPLETED);
            emit ProjectCompleted(projectId);
            accessRegistry.incrementCompletedCount(collector);
        }
    }
}
