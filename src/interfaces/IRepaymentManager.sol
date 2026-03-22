pragma solidity 0.8.24;

interface IRepaymentManager {
    function receiveBuyerPayment(uint256 projectId, uint256 amount) external;

    function distributeProceeds(uint256 projectId) external;

    function claimInvestorReturn(uint256 projectId) external;
    function claimCollectorRemainder(uint256 projectId) external;

    function previewInvestorReturn(uint256 projectId, address investor)
        external
        view
        returns (uint256 claimable);
}
