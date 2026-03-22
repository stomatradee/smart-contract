pragma solidity 0.8.24;

interface ITreasury {
    event Deposited(
        uint256 indexed projectId,
        address indexed token,
        address indexed from,
        uint256 amount
    );
    event Released(
        uint256 indexed projectId,
        address indexed token,
        address indexed to,
        uint256 amount
    );
    event PlatformWalletUpdated(address indexed oldWallet, address indexed newWallet);

    function POOL_ROLE()      external view returns (bytes32);
    function EMERGENCY_ROLE() external view returns (bytes32);

    function deposit(uint256 projectId, address token, uint256 amount, address from) external;
    function release(uint256 projectId, address token, uint256 amount, address to) external;
    function setPlatformWallet(address wallet) external;

    function projectBalances(uint256 projectId, address token) external view returns (uint256);
    function platformWallet() external view returns (address);
}
