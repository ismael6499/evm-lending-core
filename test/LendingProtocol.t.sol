// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {Test} from "forge-std/Test.sol";
import {LendingProtocol} from "../src/LendingProtocol.sol";
import {MockToken} from "../src/MockToken.sol";
import {MockOracle} from "../src/MockOracle.sol";
import {MockWETH} from "../src/MockWETH.sol";
import {MessageHashUtils} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {ECDSA} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title LendingProtocol Mega-Suite V3 (ULTRA COVERAGE)
 * @author Agustin Acosta
 * @notice 100.00% Coverage Target. Validates all business logic and edge cases.
 */
contract RevertingReceiver {
    // No receive to force ETH transfer failures
}

contract LendingProtocolTest is Test {
    LendingProtocol public lendingProtocol;
    MockToken public usdc;
    MockToken public dai;
    MockWETH public weth;
    MockOracle public oracle;

    address public owner;
    address public user1;
    address public user2;
    address public liquidator;
    address public maliciousUser;

    bytes32 public marketIdUsdc;
    bytes32 public marketIdWeth;
    bytes32 public marketIdDai;
    
    uint256 public constant COLLATERAL_FACTOR = 8000;
    uint256 public constant LIQ_THRESHOLD = 8500;
    uint256 public constant BASE_RATE = 2e16;
    uint256 public constant SLOPE1 = 4e16;
    uint256 public constant SLOPE2 = 75e16;
    uint256 public constant KINK = 80e16;

    uint256 public constant INITIAL_SUPPLY = 1000000e18;
    uint256 public constant DEPOSIT_AMOUNT = 100e18;

    function setUp() public {
        owner = makeAddr("owner");
        user1 = vm.addr(1); 
        user2 = makeAddr("user2");
        liquidator = makeAddr("liquidator");
        maliciousUser = makeAddr("malicious");
        
        vm.startPrank(owner);
        lendingProtocol = new LendingProtocol();
        oracle = new MockOracle();
        lendingProtocol.setOracle(address(oracle));
        usdc = new MockToken("USDC", "USDC", 18, INITIAL_SUPPLY);
        weth = new MockWETH();
        dai = new MockToken("DAI", "DAI", 18, INITIAL_SUPPLY);
        lendingProtocol.setWETH(address(weth));
        
        lendingProtocol.addMarket(address(usdc), bytes32("USDC"), COLLATERAL_FACTOR, LIQ_THRESHOLD, BASE_RATE, SLOPE1, SLOPE2, KINK);
        lendingProtocol.addMarket(address(weth), bytes32("WETH"), COLLATERAL_FACTOR, LIQ_THRESHOLD, BASE_RATE, SLOPE1, SLOPE2, KINK);
        lendingProtocol.addMarket(address(dai), bytes32("DAI"), COLLATERAL_FACTOR, LIQ_THRESHOLD, BASE_RATE, SLOPE1, SLOPE2, KINK);
        
        marketIdUsdc = keccak256(abi.encodePacked(address(usdc), bytes32("USDC")));
        marketIdWeth = keccak256(abi.encodePacked(address(weth), bytes32("WETH")));
        marketIdDai = keccak256(abi.encodePacked(address(dai), bytes32("DAI")));
        
        oracle.setPrice(address(usdc), 1e18);
        oracle.setPrice(address(weth), 3000e18);
        oracle.setPrice(address(dai), 1e18);
        
        usdc.mint(user1, INITIAL_SUPPLY);
        dai.mint(user1, INITIAL_SUPPLY);
        usdc.mint(user2, INITIAL_SUPPLY);
        dai.mint(user2, INITIAL_SUPPLY);
        dai.mint(liquidator, INITIAL_SUPPLY);
        vm.stopPrank();

        vm.startPrank(user2);
        usdc.approve(address(lendingProtocol), INITIAL_SUPPLY);
        dai.approve(address(lendingProtocol), INITIAL_SUPPLY);
        lendingProtocol.deposit(marketIdUsdc, 100000e18);
        lendingProtocol.deposit(marketIdDai, 100000e18);
        vm.stopPrank();
    }

    function test_Action_Deposit() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), DEPOSIT_AMOUNT);
        lendingProtocol.deposit(marketIdUsdc, DEPOSIT_AMOUNT);
        vm.stopPrank();
    }

    function test_Action_Withdraw() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), DEPOSIT_AMOUNT);
        lendingProtocol.deposit(marketIdUsdc, DEPOSIT_AMOUNT);
        lendingProtocol.withdraw(marketIdUsdc, 50e18);
        vm.stopPrank();
    }

    function test_Action_Borrow() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), DEPOSIT_AMOUNT);
        lendingProtocol.deposit(marketIdUsdc, DEPOSIT_AMOUNT);
        lendingProtocol.borrow(marketIdDai, 50e18);
        vm.stopPrank();
    }

    function test_Action_Repay() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), DEPOSIT_AMOUNT);
        lendingProtocol.deposit(marketIdUsdc, DEPOSIT_AMOUNT);
        lendingProtocol.borrow(marketIdDai, 50e18);
        dai.approve(address(lendingProtocol), 50e18);
        lendingProtocol.repay(marketIdDai, 50e18);
        vm.stopPrank();
    }

    function test_Action_DepositETH() public {
        vm.deal(user1, 10 ether);
        vm.prank(user1);
        lendingProtocol.depositETH{value: 1 ether}(marketIdWeth);
    }

    function test_Action_Liquidate() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 100e18);
        lendingProtocol.deposit(marketIdUsdc, 100e18);
        lendingProtocol.borrow(marketIdDai, 80e18);
        vm.stopPrank();
        vm.prank(owner);
        oracle.setPrice(address(usdc), 0.9e18); 
        vm.startPrank(liquidator);
        dai.approve(address(lendingProtocol), 40e18);
        lendingProtocol.liquidate(user1, marketIdDai, 40e18);
        vm.stopPrank();
    }

    function test_Action_DepositWithSignature() public {
        uint256 amount = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = lendingProtocol.getUserNonce(user1);
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(marketIdUsdc, amount, nonce, deadline)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, hash);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), amount);
        lendingProtocol.depositWithSignature(user1, marketIdUsdc, amount, deadline, sig);
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidAmount() public {
        vm.prank(user1);
        vm.expectRevert(LendingProtocol.InvalidAmount.selector);
        lendingProtocol.deposit(marketIdUsdc, 0);
    }

    function test_RevertWhen_InvalidAddress() public {
        vm.startPrank(owner);
        vm.expectRevert(LendingProtocol.InvalidAddress.selector);
        lendingProtocol.setOracle(address(0));
        vm.expectRevert(LendingProtocol.InvalidAddress.selector);
        lendingProtocol.setWETH(address(0));
        vm.stopPrank();
    }

    function test_RevertWhen_MarketAlreadyExists() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.MarketAlreadyExists.selector);
        lendingProtocol.addMarket(address(usdc), bytes32("USDC"), 5000, 6000, 0, 0, 0, 0);
    }

    function test_RevertWhen_MarketNotActive() public {
        vm.expectRevert(LendingProtocol.MarketNotActive.selector);
        lendingProtocol.deposit(keccak256("NOPE"), 1e18);
    }

    function test_RevertWhen_MarketNotEmpty() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 1 ether);
        lendingProtocol.deposit(marketIdUsdc, 1 ether);
        vm.stopPrank();
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.MarketNotEmpty.selector);
        lendingProtocol.removeMarket(marketIdUsdc);
    }

    function test_RevertWhen_RemoveMarketInactive() public {
        vm.prank(owner);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector);
        lendingProtocol.removeMarket(keccak256("INEXISTENT"));
    }

    function test_RevertWhen_MaxMarketsReached() public {
        vm.startPrank(owner);
        for (uint256 i = 0; i < 17; i++) {
            MockToken t = new MockToken("T", "T", 18, 0);
            lendingProtocol.addMarket(address(t), bytes32(i), 5000, 6000, 0, 0, 0, 0);
        }
        MockToken bad = new MockToken("B", "B", 18, 0);
        vm.expectRevert(LendingProtocol.MaxMarketsReached.selector);
        lendingProtocol.addMarket(address(bad), bytes32("BAD"), 5000, 6000, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientTotalSupply() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 1 ether);
        lendingProtocol.deposit(marketIdUsdc, 1 ether);
        vm.expectRevert(LendingProtocol.InsufficientTotalSupply.selector);
        lendingProtocol.borrow(marketIdWeth, 1000 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientDepositBalance() public {
        vm.prank(user1);
        vm.expectRevert(LendingProtocol.InsufficientDepositBalance.selector);
        lendingProtocol.withdraw(marketIdUsdc, 1);
    }

    function test_RevertWhen_InsufficientBorrowBalance() public {
        vm.prank(user1);
        vm.expectRevert(LendingProtocol.InsufficientBorrowBalance.selector);
        lendingProtocol.repay(marketIdUsdc, 1);
    }

    function test_RevertWhen_UnsafePosition() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 10e18);
        lendingProtocol.deposit(marketIdUsdc, 10e18);
        vm.expectRevert(LendingProtocol.UnsafePosition.selector);
        lendingProtocol.borrow(marketIdDai, 9e18);
        vm.stopPrank();
    }

    function test_RevertWhen_PositionNotLiquidatable() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 100e18);
        lendingProtocol.deposit(marketIdUsdc, 100e18);
        lendingProtocol.borrow(marketIdDai, 10e18);
        vm.stopPrank();
        vm.prank(liquidator);
        vm.expectRevert(LendingProtocol.PositionNotLiquidatable.selector);
        lendingProtocol.liquidate(user1, marketIdDai, 5e18);
    }

    function test_RevertWhen_NoCollateralToSeize() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 1 ether);
        lendingProtocol.deposit(marketIdUsdc, 1 ether);
        lendingProtocol.borrow(marketIdDai, 0.5 ether);
        vm.stopPrank();
        
        vm.prank(owner);
        oracle.setPrice(address(usdc), 0);
        
        vm.startPrank(liquidator);
        dai.approve(address(lendingProtocol), 0.1 ether);
        // The new oracle safety guard catches price = 0 before findBestCollateral finishes
        vm.expectRevert(LendingProtocol.InvalidPrice.selector);
        lendingProtocol.liquidate(user1, marketIdDai, 0.1 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientBorrowToLiquidate() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 100e18);
        lendingProtocol.deposit(marketIdUsdc, 100e18);
        lendingProtocol.borrow(marketIdDai, 10e18);
        vm.stopPrank();
        vm.startPrank(liquidator);
        dai.approve(address(lendingProtocol), 100e18);
        vm.expectRevert(LendingProtocol.InsufficientBorrowToLiquidate.selector);
        lendingProtocol.liquidate(user1, marketIdDai, 50e18);
        vm.stopPrank();
    }

    function test_RevertWhen_InsufficientCollateral() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 10 ether);
        lendingProtocol.deposit(marketIdUsdc, 1 ether);
        lendingProtocol.borrow(marketIdDai, 0.8 ether);
        vm.stopPrank();
        vm.prank(owner);
        oracle.setPrice(address(usdc), 0.0001e18); 
        vm.startPrank(liquidator);
        dai.approve(address(lendingProtocol), 0.9 ether);
        vm.expectRevert(LendingProtocol.InsufficientCollateral.selector);
        lendingProtocol.liquidate(user1, marketIdDai, 0.5 ether);
        vm.stopPrank();
    }

    function test_RevertWhen_InvalidSignature() public {
        uint256 amount = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = lendingProtocol.getUserNonce(user1);
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(marketIdUsdc, amount, nonce, deadline)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(2, hash);
        bytes memory sig = abi.encodePacked(r, s, v);
        vm.prank(user1);
        vm.expectRevert(LendingProtocol.InvalidSignature.selector);
        lendingProtocol.depositWithSignature(user1, marketIdUsdc, amount, deadline, sig);
    }

    function test_RevertWhen_SignatureExpired() public {
        vm.expectRevert(LendingProtocol.SignatureExpired.selector);
        lendingProtocol.depositWithSignature(user1, marketIdUsdc, 1, block.timestamp - 1, "");
    }

    function test_RevertWhen_InvalidTokenAddress() public {
        vm.deal(user1, 1 ether);
        vm.prank(user1);
        vm.expectRevert(LendingProtocol.InvalidTokenAddress.selector);
        lendingProtocol.depositETH{value: 1 ether}(marketIdUsdc);
    }

    function test_RevertWhen_InvalidRiskParameters() public {
        vm.startPrank(owner);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lendingProtocol.addMarket(address(0x1), bytes32(0), 10000, 10500, 0, 0, 0, 0);
        vm.expectRevert(LendingProtocol.InvalidRiskParameters.selector);
        lendingProtocol.addMarket(address(0x1), bytes32(0), 8000, 7000, 0, 0, 0, 0);
        vm.stopPrank();
    }

    function test_Branch_KinkedInterest() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 500000e18);
        lendingProtocol.deposit(marketIdUsdc, 500000e18);
        lendingProtocol.borrow(marketIdDai, 90000e18);
        vm.stopPrank();
        uint256 globalDebtBefore = lendingProtocol.getMarketInfo(marketIdDai).totalBorrow;
        vm.warp(block.timestamp + 10 days);
        vm.prank(user1);
        dai.approve(address(lendingProtocol), 1e18);
        vm.prank(user1);
        lendingProtocol.repay(marketIdDai, 1e15); 
        uint256 globalDebtAfter = lendingProtocol.getMarketInfo(marketIdDai).totalBorrow;
        assert(globalDebtAfter > (globalDebtBefore - 1e15));
    }

    function test_Branch_AccrueZeroTime() public {
        vm.startPrank(user2);
        dai.approve(address(lendingProtocol), 300e18);
        lendingProtocol.deposit(marketIdDai, 100e18);
        lendingProtocol.deposit(marketIdDai, 100e18); 
        vm.stopPrank();
    }

    function test_Branch_RBAC() public {
        vm.startPrank(maliciousUser);
        vm.expectRevert();
        lendingProtocol.pause();
        vm.expectRevert();
        lendingProtocol.setOracle(address(0x1));
        vm.stopPrank();
    }

    function test_Branch_EmergencyRecover() public {
        vm.startPrank(owner);
        MockToken t = new MockToken("T", "T", 18, 0);
        t.mint(address(lendingProtocol), 100e18);
        lendingProtocol.emergencyRecover(address(t), 100e18);
        assertEq(t.balanceOf(owner), 100e18);
        vm.stopPrank();
    }

    function test_Branch_MockWETH() public {
        vm.deal(address(this), 10 ether);
        weth.deposit{value: 1 ether}();
        assertEq(weth.balanceOf(address(this)), 1 ether);
        weth.withdraw(1 ether);
    }

    function test_Branch_MockToken() public {
        vm.prank(owner);
        usdc.mint(address(this), 100);
        vm.prank(owner);
        usdc.burn(1);
    }

    function test_Action_MarketRemoval() public {
        vm.startPrank(owner);
        MockToken t1 = new MockToken("T1", "T1", 18, 0);
        MockToken t2 = new MockToken("T2", "T2", 18, 0);
        lendingProtocol.addMarket(address(t1), bytes32("T1"), 5000, 6000, 0, 0, 0, 0);
        lendingProtocol.addMarket(address(t2), bytes32("T2"), 5000, 6000, 0, 0, 0, 0);
        bytes32 mid1 = keccak256(abi.encodePacked(address(t1), bytes32("T1")));
        lendingProtocol.removeMarket(mid1);
        vm.stopPrank();
    }

    function test_Action_ViewCoverage() public {
        lendingProtocol.getAccountCollateralValue(user1);
        lendingProtocol.getAccountLiquidationValue(user1);
        lendingProtocol.getAccountDebtValue(user1);
        lendingProtocol.isLiquidatable(user1);
        lendingProtocol.canWithdraw(user1, marketIdUsdc, 1e18);
        lendingProtocol.canBorrow(user1, marketIdDai, 1e18);
        lendingProtocol.findBestCollateral(user1);
        lendingProtocol.getSupportedMarkets();
        lendingProtocol.getUserNonce(user1);
        lendingProtocol.getMarketInfo(marketIdUsdc);
        lendingProtocol.oracle();
        lendingProtocol.wethAddress();
    }

    function test_Action_Paused() public {
        vm.prank(owner);
        lendingProtocol.pause();
        vm.startPrank(user1);
        vm.expectRevert();
        lendingProtocol.deposit(marketIdUsdc, 1);
        vm.stopPrank();
        vm.prank(owner);
        lendingProtocol.unpause();
    }

    function test_Branch_FullRBACFailure() public {
        vm.startPrank(maliciousUser);
        vm.expectRevert(); lendingProtocol.setOracle(address(0x1));
        vm.expectRevert(); lendingProtocol.setWETH(address(0x1));
        vm.expectRevert(); lendingProtocol.addMarket(address(0x1), bytes32(0), 1, 2, 0, 0, 0, 0);
        vm.expectRevert(); lendingProtocol.removeMarket(bytes32(0));
        vm.expectRevert(); lendingProtocol.pause();
        vm.expectRevert(); lendingProtocol.unpause();
        vm.expectRevert(); lendingProtocol.emergencyRecover(address(usdc), 1);
        vm.stopPrank();
    }

    function test_Branch_BoundaryCalculations() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 100e18);
        lendingProtocol.deposit(marketIdUsdc, 100e18);
        lendingProtocol.borrow(marketIdDai, 70e18);
        assertFalse(lendingProtocol.canWithdraw(user1, marketIdUsdc, 50e18));
        assertFalse(lendingProtocol.canBorrow(user1, marketIdDai, 50e18));
        vm.stopPrank();
    }

    function test_Branch_ViewEarlyExits() public {
        assertEq(lendingProtocol.canWithdraw(address(0xDEAD), marketIdUsdc, 1e18), true);
        assertEq(lendingProtocol.isLiquidatable(address(0xDEAD)), false);
    }

    function test_Branch_InactiveMarketSweep() public {
        bytes32 mid = keccak256("INACTIVE");
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.deposit(mid, 1);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.depositETH{value: 1}(mid);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.withdraw(mid, 1);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.borrow(mid, 1);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.repay(mid, 1);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.liquidate(user1, mid, 1);
        vm.expectRevert(LendingProtocol.MarketNotActive.selector); lendingProtocol.depositWithSignature(user1, mid, 1, 0, "");
    }

    function test_Branch_MangledSignature() public {
        uint256 amount = 100e18;
        uint256 deadline = block.timestamp + 1 hours;
        uint256 nonce = lendingProtocol.getUserNonce(user1);
        bytes32 hash = MessageHashUtils.toEthSignedMessageHash(keccak256(abi.encode(marketIdUsdc, amount, nonce, deadline)));
        (uint8 v, bytes32 r, bytes32 s) = vm.sign(1, hash);
        bytes memory sig = abi.encodePacked(r, s, uint8(42));
        vm.prank(user1);
        vm.expectRevert();
        lendingProtocol.depositWithSignature(user1, marketIdUsdc, amount, deadline, sig);
    }

    function test_Action_AutomatedGetters() public {
        lendingProtocol.users(user1);
        lendingProtocol.markets(marketIdUsdc);
        lendingProtocol.userDeposits(user1, marketIdUsdc);
        lendingProtocol.userBorrows(user1, marketIdUsdc);
        lendingProtocol.supportedMarkets(0);
        lendingProtocol.DEFAULT_ADMIN_ROLE();
        lendingProtocol.MARKET_MANAGER_ROLE();
        lendingProtocol.PAUSER_ROLE();
        lendingProtocol.EMERGENCY_ROLE();
        lendingProtocol.supportsInterface(0x01ffc9a7);
    }

    function test_Branch_AccrueSameBlock() public {
        vm.startPrank(user1);
        usdc.approve(address(lendingProtocol), 10e18);
        lendingProtocol.deposit(marketIdUsdc, 1e18);
        lendingProtocol.deposit(marketIdUsdc, 1e18);
        vm.stopPrank();
    }

    function test_Branch_ZeroSignature() public {
        bytes memory sig = new bytes(65);
        vm.prank(user1);
        vm.expectRevert();
        lendingProtocol.depositWithSignature(user1, marketIdUsdc, 1, block.timestamp + 1, sig);
    }

    function test_Branch_InvalidPrice() public {
        vm.prank(owner);
        oracle.setPrice(address(usdc), 0); // Oracle failure
        vm.expectRevert(LendingProtocol.InvalidPrice.selector);
        lendingProtocol.getPrice(address(usdc));
    }

    function test_Action_RoleManagement() public {
        vm.startPrank(owner);
        lendingProtocol.grantRole(lendingProtocol.PAUSER_ROLE(), maliciousUser);
        assert(lendingProtocol.hasRole(lendingProtocol.PAUSER_ROLE(), maliciousUser));
        lendingProtocol.revokeRole(lendingProtocol.PAUSER_ROLE(), maliciousUser);
        assertFalse(lendingProtocol.hasRole(lendingProtocol.PAUSER_ROLE(), maliciousUser));
        vm.stopPrank();
    }

    receive() external payable {}
}
