// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {SwapFacilitator} from "../src/periphery/SwapFacilitator.sol";


contract MockToken {
    string  public name;
    string  public symbol;
    uint8   public decimals = 18;
    uint256 public totalSupply;

    mapping(address => uint256) public balanceOf;
    mapping(address => mapping(address => uint256)) public allowance;

    event Transfer(address indexed from, address indexed to, uint256 amount);
    event Approval(address indexed owner, address indexed spender, uint256 amount);

    constructor(string memory _name, string memory _symbol) {
        name   = _name;
        symbol = _symbol;
    }

    function mint(address to, uint256 amount) external {
        balanceOf[to] += amount;
        totalSupply    += amount;
        emit Transfer(address(0), to, amount);
    }

    function approve(address spender, uint256 amount) external returns (bool) {
        allowance[msg.sender][spender] = amount;
        emit Approval(msg.sender, spender, amount);
        return true;
    }

    function transfer(address to, uint256 amount) external returns (bool) {
        _move(msg.sender, to, amount);
        return true;
    }

    function transferFrom(address from, address to, uint256 amount) external returns (bool) {
        uint256 allowed = allowance[from][msg.sender];
        if (allowed != type(uint256).max) allowance[from][msg.sender] = allowed - amount;
        _move(from, to, amount);
        return true;
    }

    function _move(address from, address to, uint256 amount) internal {
        balanceOf[from] -= amount;
        balanceOf[to]   += amount;
        emit Transfer(from, to, amount);
    }
}

contract MockCamelotRouter {
    // keccak256(tokenIn, tokenOut) → output rate per 1e18 input (0 = no pool)
    mapping(bytes32 => uint256) private _rates;

    receive() external payable {}

    function setRate(address tokenIn, address tokenOut, uint256 rate) external {
        _rates[_pairKey(tokenIn, tokenOut)] = rate;
    }

    function getAmountsOut(uint256 amountIn, address[] calldata path)
        external
        view
        returns (uint256[] memory amounts)
    {
        return _computeAmounts(amountIn, path);
    }

    function swapExactETHForTokens(
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external payable returns (uint256[] memory amounts) {
        amounts = _computeAmounts(msg.value, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: slippage");
        require(MockToken(path[path.length - 1]).transfer(to, amounts[amounts.length - 1]), "MockRouter: transfer failed");
    }

    function swapExactTokensForETH(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        amounts = _computeAmounts(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: slippage");
        require(MockToken(path[0]).transferFrom(msg.sender, address(this), amountIn), "MockRouter: transferFrom failed");
        (bool ok,) = to.call{value: amounts[amounts.length - 1]}("");
        require(ok, "MockRouter: ETH send failed");
    }

    function swapExactTokensForTokens(
        uint256 amountIn,
        uint256 amountOutMin,
        address[] calldata path,
        address to,
        uint256 /* deadline */
    ) external returns (uint256[] memory amounts) {
        amounts = _computeAmounts(amountIn, path);
        require(amounts[amounts.length - 1] >= amountOutMin, "MockRouter: slippage");
        require(MockToken(path[0]).transferFrom(msg.sender, address(this), amountIn), "MockRouter: transferFrom failed");
        require(MockToken(path[path.length - 1]).transfer(to, amounts[amounts.length - 1]), "MockRouter: transfer failed");
    }

    function _computeAmounts(uint256 amountIn, address[] calldata path)
        internal
        view
        returns (uint256[] memory amounts)
    {
        amounts    = new uint256[](path.length);
        amounts[0] = amountIn;
        for (uint256 i = 0; i < path.length - 1; i++) {
            uint256 rate = _rates[_pairKey(path[i], path[i + 1])];
            require(rate > 0, "MockRouter: no pool");
            amounts[i + 1] = (amounts[i] * rate) / 1e18;
        }
    }

    function _pairKey(address a, address b) internal pure returns (bytes32) {
        return keccak256(abi.encode(a, b));
    }
}


contract SwapFacilitatorTest is Test {
    // ACTORS
    address internal owner    = makeAddr("owner");
    address internal user     = makeAddr("user");
    address internal attacker = makeAddr("attacker");

    // CONTRACTS
    SwapFacilitator     internal facilitator;
    MockCamelotRouter   internal mockRouter;

    MockToken internal weth;
    MockToken internal tokenA;
    MockToken internal tokenB;

    // Stablecoin mocks (6-decimal equivalents in test)
    MockToken internal mockUsdc;
    MockToken internal mockUsdt;

    // CONSTANTS
    // Exchange rates (scaled by 1e18): rate 2e18 means 1 unit in → 2 units out.
    uint256 internal constant RATE_2X    = 2e18;
    uint256 internal constant RATE_1X    = 1e18;
    uint256 internal constant RATE_HALF  = 5e17;

    uint256 internal constant USER_ETH   = 10 ether;
    uint256 internal constant AMT_IN     = 1 ether;
    uint256 internal constant AMT_OUT_2X = 2 ether;

    uint256 internal constant USDC_AMT   = 100 * 1e6;
    uint256 internal constant USDT_AMT   = 100 * 1e6;

    uint256 internal constant ROUTER_TOKEN_BALANCE = 1_000 ether;
    uint256 internal constant ROUTER_ETH_BALANCE   = 100 ether;

    // SETUP
    function setUp() public {
        weth     = new MockToken("Wrapped Ether", "WETH");
        tokenA   = new MockToken("Token A",       "TKA");
        tokenB   = new MockToken("Token B",       "TKB");
        mockUsdc = new MockToken("Mock USDC",     "USDC");
        mockUsdt = new MockToken("Mock USDT",     "USDT");

        mockRouter = new MockCamelotRouter();

        vm.prank(owner);
        facilitator = new SwapFacilitator(
            address(mockRouter),
            address(weth),
            address(mockUsdc),
            address(mockUsdt)
        );

        tokenA.mint(address(mockRouter),   ROUTER_TOKEN_BALANCE);
        tokenB.mint(address(mockRouter),   ROUTER_TOKEN_BALANCE);
        weth.mint(address(mockRouter),     ROUTER_TOKEN_BALANCE);
        mockUsdc.mint(address(mockRouter), ROUTER_TOKEN_BALANCE);
        mockUsdt.mint(address(mockRouter), ROUTER_TOKEN_BALANCE);
        vm.deal(address(mockRouter), ROUTER_ETH_BALANCE);

        // ETH → tokenA (via WETH): 1 WETH → 2 tokenA
        mockRouter.setRate(address(weth),    address(tokenA),   RATE_2X);
        // tokenA → ETH (via WETH): 1 tokenA → 0.5 WETH
        mockRouter.setRate(address(tokenA),  address(weth),     RATE_HALF);
        // tokenA → tokenB (direct): 1:2
        mockRouter.setRate(address(tokenA),  address(tokenB),   RATE_2X);
        // tokenB → WETH: 1:1
        mockRouter.setRate(address(tokenB),  address(weth),     RATE_1X);
        // WETH → tokenB: 1:1
        mockRouter.setRate(address(weth),    address(tokenB),   RATE_1X);
        // ETH → USDC: 1 WETH → 2 USDC
        mockRouter.setRate(address(weth),    address(mockUsdc), RATE_2X);
        // ETH → USDT: 1 WETH → 2 USDT
        mockRouter.setRate(address(weth),    address(mockUsdt), RATE_2X);
        // USDC → USDT (direct): 1:1
        mockRouter.setRate(address(mockUsdc), address(mockUsdt), RATE_1X);
        // USDT → USDC (direct): 1:1
        mockRouter.setRate(address(mockUsdt), address(mockUsdc), RATE_1X);
        // USDC → WETH: 1 USDC → 0.5 WETH
        mockRouter.setRate(address(mockUsdc), address(weth),    RATE_HALF);
        // USDT → WETH: 1 USDT → 0.5 WETH
        mockRouter.setRate(address(mockUsdt), address(weth),    RATE_HALF);

        tokenA.mint(user,   100 ether);
        mockUsdc.mint(user, 1_000 * 1e6);
        mockUsdt.mint(user, 1_000 * 1e6);
        vm.deal(user, USER_ETH);

        vm.startPrank(user);
        tokenA.approve(address(facilitator),   type(uint256).max);
        tokenB.approve(address(facilitator),   type(uint256).max);
        mockUsdc.approve(address(facilitator), type(uint256).max);
        mockUsdt.approve(address(facilitator), type(uint256).max);
        vm.stopPrank();
    }

    // 1. DEPLOYMENT
    function test_deployment_ownerIsDeployer() public view {
        assertEq(facilitator.owner(), owner);
    }

    function test_deployment_routerWired() public view {
        assertEq(address(facilitator.CAMELOT_ROUTER()), address(mockRouter));
    }

    function test_deployment_wethImmutable() public view {
        assertEq(facilitator.WETH(), address(weth));
    }

    function test_deployment_usdcAndUsdtSet() public view {
        assertEq(facilitator.USDC(), address(mockUsdc));
        assertEq(facilitator.USDT(), address(mockUsdt));
    }

    function test_deployment_revertOnZeroRouter() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        new SwapFacilitator(address(0), address(weth), address(mockUsdc), address(mockUsdt));
    }

    function test_deployment_revertOnZeroWeth() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        new SwapFacilitator(address(mockRouter), address(0), address(mockUsdc), address(mockUsdt));
    }

    function test_deployment_revertOnZeroUsdc() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        new SwapFacilitator(address(mockRouter), address(weth), address(0), address(mockUsdt));
    }

    function test_deployment_revertOnZeroUsdt() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        new SwapFacilitator(address(mockRouter), address(weth), address(mockUsdc), address(0));
    }

    // 2. SWAPEXACTETHFORTOKEN
    function test_swapETHForToken_transfersTokenToUser() public {
        uint256 before = tokenA.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), 0);

        assertEq(tokenA.balanceOf(user) - before, AMT_OUT_2X);
    }

    function test_swapETHForToken_emitsSwappedEvent() public {
        vm.expectEmit(true, true, true, false, address(facilitator));
        emit SwapFacilitator.Swapped(address(0), address(tokenA), AMT_IN, 0, user);

        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), 0);
    }

    function test_swapETHForToken_forwardsAllETHToRouter() public {
        uint256 routerBefore = address(mockRouter).balance;

        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), 0);

        assertEq(address(mockRouter).balance, routerBefore + AMT_IN);
    }

    function test_swapETHForToken_facilitatorHoldsNoTokensAfterSwap() public {
        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), 0);

        assertEq(tokenA.balanceOf(address(facilitator)), 0);
    }

    function test_swapETHForToken_revertWhenNoETHSent() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__NoETHSent.selector);
        vm.prank(user);
        facilitator.swapExactEthForToken{value: 0}(address(tokenA), 0);
    }

    function test_swapETHForToken_revertOnZeroTokenOut() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(0), 0);
    }

    function test_swapETHForToken_revertWhenTokenOutIsWETH() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__SameToken.selector);
        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(weth), 0);
    }

    function test_swapETHForToken_revertWhenSlippageNotMet() public {
        uint256 tooHighMin = AMT_OUT_2X + 1;
        vm.expectRevert();
        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), tooHighMin);
    }

    // 3. SWAPEXACTTOKENFORETH
    function test_swapTokenForETH_transfersETHToUser() public {
        uint256 expectedOut = (AMT_IN * RATE_HALF) / 1e18;
        uint256 before = user.balance;

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, 0);

        assertEq(user.balance - before, expectedOut);
    }

    function test_swapTokenForETH_pullsTokensFromUser() public {
        uint256 before = tokenA.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, 0);

        assertEq(before - tokenA.balanceOf(user), AMT_IN);
    }

    function test_swapTokenForETH_facilitatorHoldsNoAssetsAfterSwap() public {
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, 0);

        assertEq(tokenA.balanceOf(address(facilitator)), 0);
        assertEq(address(facilitator).balance, 0);
    }

    function test_swapTokenForETH_revokesApprovalAfterSwap() public {
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, 0);

        assertEq(tokenA.allowance(address(facilitator), address(mockRouter)), 0);
    }

    function test_swapTokenForETH_emitsSwappedEvent() public {
        uint256 expectedOut = (AMT_IN * RATE_HALF) / 1e18;

        vm.expectEmit(true, true, true, false, address(facilitator));
        emit SwapFacilitator.Swapped(address(tokenA), address(0), AMT_IN, expectedOut, user);

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, 0);
    }

    function test_swapTokenForETH_revertOnZeroAmount() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAmount.selector);
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), 0, 0);
    }

    function test_swapTokenForETH_revertOnZeroTokenAddress() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(0), AMT_IN, 0);
    }

    function test_swapTokenForETH_revertWhenTokenInIsWETH() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__SameToken.selector);
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(weth), AMT_IN, 0);
    }

    function test_swapTokenForETH_revertWhenSlippageNotMet() public {
        uint256 tooHighMin = 1000 ether;
        vm.expectRevert();
        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), AMT_IN, tooHighMin);
    }

    // 4. SWAPEXACTTOKENFORTOKEN — DIRECT PATH
    function test_swapTokenForToken_directPath_transfersCorrectAmount() public {
        uint256 before = tokenB.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, 0);

        assertEq(tokenB.balanceOf(user) - before, AMT_OUT_2X);
    }

    function test_swapTokenForToken_directPath_pullsTokenIn() public {
        uint256 before = tokenA.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, 0);

        assertEq(before - tokenA.balanceOf(user), AMT_IN);
    }

    function test_swapTokenForToken_directPath_emitsSwappedEvent() public {
        vm.expectEmit(true, true, true, false, address(facilitator));
        emit SwapFacilitator.Swapped(address(tokenA), address(tokenB), AMT_IN, 0, user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, 0);
    }

    function test_swapTokenForToken_directPath_revokesApproval() public {
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, 0);

        assertEq(tokenA.allowance(address(facilitator), address(mockRouter)), 0);
    }

    function test_swapTokenForToken_directPath_facilitatorHoldsNoTokens() public {
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, 0);

        assertEq(tokenA.balanceOf(address(facilitator)), 0);
        assertEq(tokenB.balanceOf(address(facilitator)), 0);
    }

    function test_swapTokenForToken_revertOnZeroAmountIn() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAmount.selector);
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), 0, 0);
    }

    function test_swapTokenForToken_revertOnSameToken() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__SameToken.selector);
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenA), AMT_IN, 0);
    }

    function test_swapTokenForToken_revertOnZeroTokenInAddress() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__ZeroAddress.selector);
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(0), address(tokenB), AMT_IN, 0);
    }

    function test_swapTokenForToken_revertWhenSlippageNotMet() public {
        uint256 tooHighMin = 1000 ether;
        vm.expectRevert();
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), AMT_IN, tooHighMin);
    }

    // 5. SWAPEXACTTOKENFORTOKEN — WETH-HOP FALLBACK
    function test_swapTokenForToken_wethHop_usedWhenNoDirectPool() public {
        // No direct tokenB → tokenA pool.
        // tokenB → WETH (1:1), WETH → tokenA (1:2). Expected: 2 tokenA.
        tokenB.mint(user, 10 ether);
        vm.prank(user);
        tokenB.approve(address(facilitator), type(uint256).max);

        uint256 before = tokenA.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenB), address(tokenA), AMT_IN, 0);

        assertEq(tokenA.balanceOf(user) - before, AMT_OUT_2X);
    }

    function test_swapTokenForToken_wethHop_revertWhenNeitherPathExists() public {
        MockToken tokenC = new MockToken("Token C", "TKC");
        tokenC.mint(user, 10 ether);
        vm.prank(user);
        tokenC.approve(address(facilitator), type(uint256).max);

        vm.expectRevert(abi.encodeWithSelector(
            SwapFacilitator.SwapFacilitator__NoPriceAvailable.selector, address(tokenC), address(tokenA)
        ));
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenC), address(tokenA), AMT_IN, 0);
    }

    function test_swapTokenForToken_wethHop_notAttemptedWhenTokenInIsWETH() public {
        // WETH → tokenB direct pool exists (RATE_1X). Should succeed via direct path.
        weth.mint(user, 10 ether);
        vm.prank(user);
        weth.approve(address(facilitator), type(uint256).max);

        uint256 before = tokenB.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(weth), address(tokenB), AMT_IN, 0);

        assertEq(tokenB.balanceOf(user) - before, AMT_IN); // 1:1
    }

    // 6. STABLECOIN CONVENIENCE — SWAPETHFORUSDC / SWAPETHFORUSDT
    function test_swapETHForUSDC_transfersUsdcToUser() public {
        uint256 expected = (AMT_IN * RATE_2X) / 1e18;
        uint256 before   = mockUsdc.balanceOf(user);

        vm.prank(user);
        facilitator.swapEthForUsdc{value: AMT_IN}(0);

        assertEq(mockUsdc.balanceOf(user) - before, expected);
    }

    function test_swapETHForUSDC_emitsSwappedEvent() public {
        vm.expectEmit(true, true, true, false, address(facilitator));
        emit SwapFacilitator.Swapped(address(0), address(mockUsdc), AMT_IN, 0, user);

        vm.prank(user);
        facilitator.swapEthForUsdc{value: AMT_IN}(0);
    }

    function test_swapETHForUSDC_facilitatorHoldsNothing() public {
        vm.prank(user);
        facilitator.swapEthForUsdc{value: AMT_IN}(0);

        assertEq(mockUsdc.balanceOf(address(facilitator)), 0);
        assertEq(address(facilitator).balance, 0);
    }

    function test_swapETHForUSDC_revertWhenNoETHSent() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__NoETHSent.selector);
        vm.prank(user);
        facilitator.swapEthForUsdc{value: 0}(0);
    }

    function test_swapETHForUSDC_revertWhenSlippageNotMet() public {
        uint256 expected   = (AMT_IN * RATE_2X) / 1e18;
        uint256 tooHighMin = expected + 1;
        vm.expectRevert();
        vm.prank(user);
        facilitator.swapEthForUsdc{value: AMT_IN}(tooHighMin);
    }

    function test_swapETHForUSDT_transfersUsdtToUser() public {
        uint256 expected = (AMT_IN * RATE_2X) / 1e18;
        uint256 before   = mockUsdt.balanceOf(user);

        vm.prank(user);
        facilitator.swapEthForUsdt{value: AMT_IN}(0);

        assertEq(mockUsdt.balanceOf(user) - before, expected);
    }

    function test_swapETHForUSDT_emitsSwappedEvent() public {
        vm.expectEmit(true, true, true, false, address(facilitator));
        emit SwapFacilitator.Swapped(address(0), address(mockUsdt), AMT_IN, 0, user);

        vm.prank(user);
        facilitator.swapEthForUsdt{value: AMT_IN}(0);
    }

    function test_swapETHForUSDT_facilitatorHoldsNothing() public {
        vm.prank(user);
        facilitator.swapEthForUsdt{value: AMT_IN}(0);

        assertEq(mockUsdt.balanceOf(address(facilitator)), 0);
        assertEq(address(facilitator).balance, 0);
    }

    function test_swapETHForUSDT_revertWhenNoETHSent() public {
        vm.expectRevert(SwapFacilitator.SwapFacilitator__NoETHSent.selector);
        vm.prank(user);
        facilitator.swapEthForUsdt{value: 0}(0);
    }

    // 7. STABLECOIN-SPECIFIC SWAPS (USDC↔USDT, USDC/USDT→ETH)
    function test_swapUSDCToUSDT_directPath() public {
        uint256 expected = (USDC_AMT * RATE_1X) / 1e18;
        uint256 before   = mockUsdt.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(mockUsdc), address(mockUsdt), USDC_AMT, 0);

        assertEq(mockUsdt.balanceOf(user) - before, expected);
    }

    function test_swapUSDTToUSDC_directPath() public {
        uint256 expected = (USDT_AMT * RATE_1X) / 1e18;
        uint256 before   = mockUsdc.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(mockUsdt), address(mockUsdc), USDT_AMT, 0);

        assertEq(mockUsdc.balanceOf(user) - before, expected);
    }

    function test_swapUSDCToETH_viaCamelot() public {
        uint256 expectedEth = (USDC_AMT * RATE_HALF) / 1e18;
        uint256 before      = user.balance;

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(mockUsdc), USDC_AMT, 0);

        assertEq(user.balance - before, expectedEth);
    }

    function test_swapUSDTToETH_viaCamelot() public {
        uint256 expectedEth = (USDT_AMT * RATE_HALF) / 1e18;
        uint256 before      = user.balance;

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(mockUsdt), USDT_AMT, 0);

        assertEq(user.balance - before, expectedEth);
    }

    function test_swapETHToUSDC_viaGenericFunction() public {
        uint256 expected = (AMT_IN * RATE_2X) / 1e18;
        uint256 before   = mockUsdc.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(mockUsdc), 0);

        assertEq(mockUsdc.balanceOf(user) - before, expected);
    }

    function test_swapUSDCToUSDT_revokesApproval() public {
        vm.prank(user);
        facilitator.swapExactTokenForToken(address(mockUsdc), address(mockUsdt), USDC_AMT, 0);

        assertEq(mockUsdc.allowance(address(facilitator), address(mockRouter)), 0);
    }

    // 8. GET QUOTE
    function test_getQuote_returnsDirectQuoteWhenAvailable() public view {
        uint256 quote = facilitator.getQuote(address(tokenA), address(tokenB), AMT_IN);
        assertEq(quote, AMT_OUT_2X);
    }

    function test_getQuote_returnsWethHopQuoteWhenNoDirectPool() public view {
        // tokenB → WETH (1:1) → tokenA (1:2): expected = 2 tokenA
        uint256 quote = facilitator.getQuote(address(tokenB), address(tokenA), AMT_IN);
        assertEq(quote, AMT_OUT_2X);
    }

    function test_getQuote_returnsZeroWhenNoPriceAvailable() public view {
        address unknownToken = address(0xDEAD);
        uint256 quote = facilitator.getQuote(unknownToken, address(tokenA), AMT_IN);
        assertEq(quote, 0);
    }

    function test_getQuote_returnsZeroOnZeroAmountIn() public view {
        uint256 quote = facilitator.getQuote(address(tokenA), address(tokenB), 0);
        assertEq(quote, 0);
    }

    function test_getQuote_returnsZeroWhenSameToken() public view {
        uint256 quote = facilitator.getQuote(address(tokenA), address(tokenA), AMT_IN);
        assertEq(quote, 0);
    }

    function test_getQuote_returnsZeroOnZeroAddress() public view {
        uint256 quote = facilitator.getQuote(address(0), address(tokenA), AMT_IN);
        assertEq(quote, 0);
    }

    function test_getQuote_directBeforeHop_prefersDirect() public view {
        uint256 directQuote = facilitator.getQuote(address(tokenA), address(tokenB), AMT_IN);
        assertEq(directQuote, AMT_OUT_2X);
    }

    function test_getQuote_multiHop_correctComposition() public view {
        // tokenB → WETH (1:1) → tokenA (1:2): expected = 2 tokenA
        uint256 quote = facilitator.getQuote(address(tokenB), address(tokenA), AMT_IN);
        assertEq(quote, AMT_OUT_2X);
    }

    function test_getQuote_usdcToUsdt_returnsCorrectQuote() public view {
        uint256 quote = facilitator.getQuote(address(mockUsdc), address(mockUsdt), USDC_AMT);
        assertEq(quote, (USDC_AMT * RATE_1X) / 1e18);
    }

    // 9. EDGE CASES & FUZZ
    function test_facilitator_doesNotHoldETHFromSwapETHForToken() public {
        uint256 before = address(facilitator).balance;
        vm.prank(user);
        facilitator.swapExactEthForToken{value: AMT_IN}(address(tokenA), 0);
        assertEq(address(facilitator).balance, before);
    }

    function test_facilitator_receiveETHFallback() public {
        vm.deal(address(this), 1 ether);
        (bool ok,) = address(facilitator).call{value: 1 ether}("");
        assertTrue(ok);
        assertEq(address(facilitator).balance, 1 ether);
    }

    function testFuzz_swapETHForToken_amountScalesLinearly(uint96 ethIn) public {
        vm.assume(ethIn > 0 && ethIn <= 10 ether);

        uint256 expected = (uint256(ethIn) * RATE_2X) / 1e18;
        uint256 before   = tokenA.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactEthForToken{value: ethIn}(address(tokenA), 0);

        assertEq(tokenA.balanceOf(user) - before, expected);
    }

    function testFuzz_swapTokenForETH_amountScalesLinearly(uint96 amtIn) public {
        vm.assume(amtIn > 0 && amtIn <= 50 ether);

        uint256 expected = (uint256(amtIn) * RATE_HALF) / 1e18;
        vm.deal(address(mockRouter), ROUTER_ETH_BALANCE + expected);

        tokenA.mint(user, amtIn);
        uint256 ethBefore = user.balance;

        vm.prank(user);
        facilitator.swapExactTokenForEth(address(tokenA), amtIn, 0);

        assertEq(user.balance - ethBefore, expected);
    }

    function testFuzz_swapTokenForToken_amountScalesLinearly(uint96 amtIn) public {
        vm.assume(amtIn > 0 && amtIn <= 50 ether);

        uint256 expected = (uint256(amtIn) * RATE_2X) / 1e18;
        tokenA.mint(user, amtIn);
        uint256 before = tokenB.balanceOf(user);

        vm.prank(user);
        facilitator.swapExactTokenForToken(address(tokenA), address(tokenB), amtIn, 0);

        assertEq(tokenB.balanceOf(user) - before, expected);
    }
}
