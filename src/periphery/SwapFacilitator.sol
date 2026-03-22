pragma solidity 0.8.24;

import {Ownable}         from "@openzeppelin/contracts/access/Ownable.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {SafeERC20}       from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {IERC20}          from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {ICamelotRouter}  from "../interfaces/ICamelotRouter.sol";

contract SwapFacilitator is Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;

    error SwapFacilitator__ZeroAddress();
    error SwapFacilitator__ZeroAmount();
    error SwapFacilitator__NoETHSent();
    error SwapFacilitator__SameToken();
    error SwapFacilitator__NoPriceAvailable(address tokenIn, address tokenOut);
    error SwapFacilitator__InsufficientOutput(uint256 amountOut, uint256 minAmountOut);

    event Swapped(
        address indexed tokenIn,
        address indexed tokenOut,
        uint256 amountIn,
        uint256 amountOut,
        address indexed recipient
    );

    ICamelotRouter public immutable CAMELOT_ROUTER;
    address        public immutable WETH;
    address        public immutable USDC;
    address        public immutable USDT;

    constructor(
        address router_,
        address weth_,
        address usdc_,
        address usdt_
    ) Ownable(msg.sender) {
        if (router_ == address(0)) revert SwapFacilitator__ZeroAddress();
        if (weth_   == address(0)) revert SwapFacilitator__ZeroAddress();
        if (usdc_   == address(0)) revert SwapFacilitator__ZeroAddress();
        if (usdt_   == address(0)) revert SwapFacilitator__ZeroAddress();
        CAMELOT_ROUTER = ICamelotRouter(router_);
        WETH           = weth_;
        USDC           = usdc_;
        USDT           = usdt_;
    }

    function swapExactEthForToken(address tokenOut, uint256 minAmountOut)
        external
        payable
        nonReentrant
    {
        _executeEthForToken(tokenOut, minAmountOut);
    }

    function swapExactTokenForEth(
        address tokenIn,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant {
        if (tokenIn == address(0)) revert SwapFacilitator__ZeroAddress();
        if (amountIn == 0)         revert SwapFacilitator__ZeroAmount();
        if (tokenIn == WETH)       revert SwapFacilitator__SameToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(CAMELOT_ROUTER), amountIn);

        address[] memory path = new address[](2);
        path[0] = tokenIn;
        path[1] = WETH;

        uint256[] memory amounts = CAMELOT_ROUTER.swapExactTokensForETH(
            amountIn, minAmountOut, path, msg.sender, block.timestamp
        );

        IERC20(tokenIn).forceApprove(address(CAMELOT_ROUTER), 0);
        emit Swapped(tokenIn, address(0), amountIn, amounts[amounts.length - 1], msg.sender);
    }

    function swapExactTokenForToken(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        uint256 minAmountOut
    ) external nonReentrant {
        if (tokenIn == address(0) || tokenOut == address(0)) revert SwapFacilitator__ZeroAddress();
        if (amountIn == 0)       revert SwapFacilitator__ZeroAmount();
        if (tokenIn == tokenOut) revert SwapFacilitator__SameToken();

        IERC20(tokenIn).safeTransferFrom(msg.sender, address(this), amountIn);
        IERC20(tokenIn).forceApprove(address(CAMELOT_ROUTER), amountIn);

        (address[] memory path,) = _bestPath(tokenIn, tokenOut, amountIn);

        uint256[] memory amounts = CAMELOT_ROUTER.swapExactTokensForTokens(
            amountIn, minAmountOut, path, msg.sender, block.timestamp
        );

        IERC20(tokenIn).forceApprove(address(CAMELOT_ROUTER), 0);
        emit Swapped(tokenIn, tokenOut, amountIn, amounts[amounts.length - 1], msg.sender);
    }

    function swapEthForUsdc(uint256 minAmountOut) external payable nonReentrant {
        _executeEthForToken(USDC, minAmountOut);
    }

    function swapEthForUsdt(uint256 minAmountOut) external payable nonReentrant {
        _executeEthForToken(USDT, minAmountOut);
    }

    function getQuote(address tokenIn, address tokenOut, uint256 amountIn)
        external
        view
        returns (uint256 amountOut)
    {
        if (amountIn == 0 || tokenIn == tokenOut) return 0;
        if (tokenIn == address(0) || tokenOut == address(0)) return 0;

        (bool directOk, uint256 directOut) = _tryQuote(tokenIn, tokenOut, amountIn, false);
        if (directOk) return directOut;

        if (tokenIn != WETH && tokenOut != WETH) {
            (, uint256 hopOut) = _tryQuote(tokenIn, tokenOut, amountIn, true);
            return hopOut;
        }

        return 0;
    }

    function _executeEthForToken(address tokenOut, uint256 minAmountOut) private {
        if (msg.value == 0)         revert SwapFacilitator__NoETHSent();
        if (tokenOut == address(0)) revert SwapFacilitator__ZeroAddress();
        if (tokenOut == WETH)       revert SwapFacilitator__SameToken();

        address[] memory path = new address[](2);
        path[0] = WETH;
        path[1] = tokenOut;

        uint256[] memory amounts = CAMELOT_ROUTER.swapExactETHForTokens{value: msg.value}(
            minAmountOut, path, msg.sender, block.timestamp
        );

        emit Swapped(address(0), tokenOut, msg.value, amounts[amounts.length - 1], msg.sender);
    }

    function _tryQuote(
        address tokenIn,
        address tokenOut,
        uint256 amountIn,
        bool viaWeth
    ) internal view returns (bool success, uint256 amountOut) {
        address[] memory path;

        if (viaWeth) {
            path    = new address[](3);
            path[0] = tokenIn;
            path[1] = WETH;
            path[2] = tokenOut;
        } else {
            path    = new address[](2);
            path[0] = tokenIn;
            path[1] = tokenOut;
        }

        try ICamelotRouter(address(CAMELOT_ROUTER)).getAmountsOut(amountIn, path)
            returns (uint256[] memory amounts)
        {
            success   = true;
            amountOut = amounts[amounts.length - 1];
        } catch {
            success   = false;
            amountOut = 0;
        }
    }

    function _bestPath(
        address tokenIn,
        address tokenOut,
        uint256 amountIn
    ) internal view returns (address[] memory path, uint256 amountOut) {
        (bool directOk, uint256 directOut) = _tryQuote(tokenIn, tokenOut, amountIn, false);
        if (directOk) {
            path      = new address[](2);
            path[0]   = tokenIn;
            path[1]   = tokenOut;
            amountOut = directOut;
            return (path, amountOut);
        }

        if (tokenIn != WETH && tokenOut != WETH) {
            (bool hopOk, uint256 hopOut) = _tryQuote(tokenIn, tokenOut, amountIn, true);
            if (hopOk) {
                path      = new address[](3);
                path[0]   = tokenIn;
                path[1]   = WETH;
                path[2]   = tokenOut;
                amountOut = hopOut;
                return (path, amountOut);
            }
        }

        revert SwapFacilitator__NoPriceAvailable(tokenIn, tokenOut);
    }

    receive() external payable {}
}
