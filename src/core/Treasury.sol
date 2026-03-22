pragma solidity 0.8.24;

import {AccessControl}   from "@openzeppelin/contracts/access/AccessControl.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ITreasury}       from "../interfaces/ITreasury.sol";

contract Treasury is AccessControl, ReentrancyGuard, ITreasury {
    using SafeERC20 for IERC20;

    error Treasury__ZeroAddress();
    error Treasury__ZeroAmount();
    error Treasury__InsufficientProjectBalance(
        uint256 projectId,
        address token,
        uint256 requested,
        uint256 available
    );

    bytes32 public constant POOL_ROLE      = keccak256("POOL_ROLE");
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    mapping(uint256 => mapping(address => uint256)) public projectBalances;
    address public platformWallet;

    constructor(address admin, address initialWallet) {
        if (admin == address(0))         revert Treasury__ZeroAddress();
        if (initialWallet == address(0)) revert Treasury__ZeroAddress();

        _grantRole(DEFAULT_ADMIN_ROLE, admin);
        platformWallet = initialWallet;
        emit PlatformWalletUpdated(address(0), initialWallet);
    }

    function deposit(
        uint256 projectId,
        address token,
        uint256 amount,
        address from
    ) external onlyRole(POOL_ROLE) {
        if (token == address(0)) revert Treasury__ZeroAddress();
        if (from  == address(0)) revert Treasury__ZeroAddress();
        if (amount == 0)         revert Treasury__ZeroAmount();

        projectBalances[projectId][token] += amount;

        emit Deposited(projectId, token, from, amount);
    }

    function release(
        uint256 projectId,
        address token,
        uint256 amount,
        address to
    ) external onlyRole(POOL_ROLE) nonReentrant {
        if (token  == address(0)) revert Treasury__ZeroAddress();
        if (to     == address(0)) revert Treasury__ZeroAddress();
        if (amount == 0)          revert Treasury__ZeroAmount();

        uint256 available = projectBalances[projectId][token];
        if (amount > available) {
            revert Treasury__InsufficientProjectBalance(projectId, token, amount, available);
        }

        projectBalances[projectId][token] = available - amount;

        IERC20(token).safeTransfer(to, amount);
        emit Released(projectId, token, to, amount);
    }

    function setPlatformWallet(address wallet) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (wallet == address(0)) revert Treasury__ZeroAddress();

        address old = platformWallet;
        platformWallet = wallet;
        emit PlatformWalletUpdated(old, wallet);
    }
}
