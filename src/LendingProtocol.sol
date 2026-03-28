// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {AccessControl} from "../lib/openzeppelin-contracts/contracts/access/AccessControl.sol";
import {ECDSA} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";
import {IOracle} from "./interfaces/IOracle.sol";
import {IWETH} from "./interfaces/IWETH.sol";

/**
 * @title LendingProtocol V3 (Institutional Grade)
 * @author Agustin Acosta
 * @notice An enterprise-grade, decentralised lending and borrowing protocol with advanced risk management.
 * @dev Implements RBAC (AccessControl), Pausability, Kinked Interest Rate Models, and segmented Risk Thresholds.
 * Uses a two-slope utilization curve to manage liquidity pressure and provides a safety buffer via a 
 * separate Liquidation Threshold.
 */
contract LendingProtocol is ReentrancyGuard, Pausable, AccessControl {
    using SafeERC20 for IERC20;
    using ECDSA for bytes;

    // ============ CONSTANTS & ROLES ============

    /**
     * @notice Global identifier for market management authorities.
     */
    bytes32 public constant MARKET_MANAGER_ROLE = keccak256("MARKET_MANAGER_ROLE");

    /**
     * @notice Global identifier for emergency stopping authorities.
     */
    bytes32 public constant PAUSER_ROLE = keccak256("PAUSER_ROLE");

    /**
     * @notice Role for asset recovery and protocol protection.
     */
    bytes32 public constant EMERGENCY_ROLE = keccak256("EMERGENCY_ROLE");

    /**
     * @notice Common denominator for percentage-based calculations.
     */
    uint256 public constant BASIS_POINTS = 10000;

    /**
     * @notice Reward paid to liquidators over the debt repayment.
     */
    uint256 public constant LIQUIDATION_PENALTY = 500;

    /**
     * @notice Protocol cut from the accrued interest.
     */
    uint256 public constant RESERVE_FACTOR = 1000;

    /**
     * @notice Hard cap on the number of concurrently supported asset markets.
     */
    uint256 public constant MAX_MARKETS = 20;

    // ============ DATA STRUCTURES ============

    /**
     * @title Market Parameters
     * @notice Encapsulates asset-specific risk and interest configurations.
     */
    struct Market {
        IERC20 token;
        bool isActive;
        uint256 collateralFactor;      // Maximum LTV in basis points.
        uint256 liquidationThreshold;  // Debt-to-Collateral point for liquidations.
        uint256 totalSupply;           // Cumulative supplied asset amount.
        uint256 totalBorrow;           // Cumulative debt balance in this market.
        uint256 lastAccrualTime;       // Block timestamp of the last interest event.
        uint256 baseRate;      // Annual percentage rate at 0% utilization.
        uint256 slope1;        // Multiplier applied to utilization before the kink.
        uint256 slope2;        // Aggressive multiplier applied after the kink.
        uint256 kink;          // Utilization threshold where slope2 becomes active.
    }

    /**
     * @title User Records
     * @notice Tracks account-level protocol activity.
     */
    struct User {
        bool isActive;
        uint256 lastUpdateTime;
        uint256 nonce;
    }

    // ============ STATE VARIABLES ============

    /**
     * @notice Master price oracle reference for asset valuations.
     */
    IOracle public oracle;

    /**
     * @notice Canonical WETH address for native ETH wrapping.
     */
    address public wethAddress;

    /**
     * @notice Dynamic list of all market IDs registered in the system.
     */
    bytes32[] public supportedMarkets;

    /**
     * @notice Mapping of hashed identifiers to market configurations.
     */
    mapping(bytes32 => Market) public markets;

    /**
     * @notice Tracking of user deposits per market per address.
     */
    mapping(address => mapping(bytes32 => uint256)) public userDeposits;

    /**
     * @notice Tracking of gross user debt per market per address.
     */
    mapping(address => mapping(bytes32 => uint256)) public userBorrows;

    /**
     * @notice Registry of global user metadata and security nonces.
     */
    mapping(address => User) public users;

    // ============ EVENTS ============

    event MarketAdded(bytes32 indexed marketId, address indexed token, uint256 collateralFactor, uint256 liquidationThreshold);
    event MarketRemoved(bytes32 indexed marketId);
    event Deposit(address indexed user, bytes32 indexed marketId, uint256 amount);
    event Withdraw(address indexed user, bytes32 indexed marketId, uint256 amount);
    event Borrow(address indexed user, bytes32 indexed marketId, uint256 amount);
    event Repay(address indexed user, bytes32 indexed marketId, uint256 amount);
    event Liquidate(address indexed liquidator, address indexed user, bytes32 indexed debtMarketId, uint256 collateralSeized);
    event OracleUpdated(address indexed newOracle);

    // ============ ERRORS ============

    error InvalidAmount();
    error InvalidAddress();
    error MarketAlreadyExists();
    error MarketNotActive();
    error MarketNotEmpty();
    error MaxMarketsReached();
    error InsufficientTotalSupply();
    error InsufficientDepositBalance();
    error InsufficientBorrowBalance();
    error UnsafePosition();
    error PositionNotLiquidatable();
    error NoCollateralToSeize();
    error InsufficientBorrowToLiquidate();
    error InsufficientCollateral();
    error InvalidSignature();
    error SignatureExpired();
    error InvalidTokenAddress();
    error InvalidPrice();
    error InvalidRiskParameters();

    // ============ CONSTRUCTOR ============

    /**
     * @notice Initializes the protocol V3, granting all initial roles to the deployer.
     * @dev Author: Agustin Acosta
     */
    constructor() {
        _grantRole(DEFAULT_ADMIN_ROLE, msg.sender);
        _grantRole(MARKET_MANAGER_ROLE, msg.sender);
        _grantRole(PAUSER_ROLE, msg.sender);
        _grantRole(EMERGENCY_ROLE, msg.sender);
    }

    // ============ MODIFIERS ============

    /**
     * @notice Ensures the target market is operational.
     */
    modifier onlyActiveMarket(bytes32 _marketId) {
        if (!markets[_marketId].isActive) revert MarketNotActive();
        _;
    }

    // ============ ADMIN ACTIONS ============

    /**
     * @notice Point the protocol to a specific price oracle.
     */
    function setOracle(address _oracleAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_oracleAddress == address(0)) revert InvalidAddress();
        oracle = IOracle(_oracleAddress);
        emit OracleUpdated(_oracleAddress);
    }

    /**
     * @notice Defines the canonical WETH implementation to use for native ETH deposits.
     */
    function setWETH(address _wethAddress) external onlyRole(DEFAULT_ADMIN_ROLE) {
        if (_wethAddress == address(0)) revert InvalidAddress();
        wethAddress = _wethAddress;
    }

    /**
     * @notice Registers a new asset with safety and interest parameters.
     * @dev Implements a Two-Slope Interest Model for dynamic rate adjustment.
     */
    function addMarket(
        address _tokenAddress, 
        bytes32 _salt, 
        uint256 _collateralFactor, 
        uint256 _liquidationThreshold,
        uint256 _baseRate,
        uint256 _slope1,
        uint256 _slope2,
        uint256 _kink
    ) external onlyRole(MARKET_MANAGER_ROLE) {
        if (_tokenAddress == address(0)) revert InvalidAddress();
        if (_collateralFactor >= BASIS_POINTS || _liquidationThreshold <= _collateralFactor || _liquidationThreshold >= BASIS_POINTS) revert InvalidRiskParameters();
        if (supportedMarkets.length >= MAX_MARKETS) revert MaxMarketsReached();

        bytes32 marketId = keccak256(abi.encodePacked(_tokenAddress, _salt));
        if (markets[marketId].isActive) revert MarketAlreadyExists();

        markets[marketId] = Market({
            token: IERC20(_tokenAddress),
            isActive: true,
            collateralFactor: _collateralFactor,
            liquidationThreshold: _liquidationThreshold,
            totalSupply: 0,
            totalBorrow: 0,
            lastAccrualTime: block.timestamp,
            baseRate: _baseRate,
            slope1: _slope1,
            slope2: _slope2,
            kink: _kink
        });

        supportedMarkets.push(marketId);
        emit MarketAdded(marketId, _tokenAddress, _collateralFactor, _liquidationThreshold);
    }

    /**
     * @notice Removes a market if it possesses no liquidity or debt.
     */
    function removeMarket(bytes32 _marketId) external onlyRole(MARKET_MANAGER_ROLE) {
        if (!markets[_marketId].isActive) revert MarketNotActive();
        if (markets[_marketId].totalSupply > 0) revert MarketNotEmpty();
        delete markets[_marketId];
        uint256 length = supportedMarkets.length;
        for (uint256 i = 0; i < length; i++) {
            if (supportedMarkets[i] == _marketId) {
                supportedMarkets[i] = supportedMarkets[length - 1];
                supportedMarkets.pop();
                break;
            }
        }
        emit MarketRemoved(_marketId);
    }

    /**
     * @notice Imposes an emergency halt on the protocol.
     */
    function pause() external onlyRole(PAUSER_ROLE) { _pause(); }

    /**
     * @notice Lifts an emergency halt.
     */
    function unpause() external onlyRole(PAUSER_ROLE) { _unpause(); }

    /**
     * @notice Rescues ERC20 tokens mistakenly sent to the protocol.
     */
    function emergencyRecover(address _tokenAddress, uint256 _amount) external onlyRole(EMERGENCY_ROLE) {
        if (_amount == 0) revert InvalidAmount();
        IERC20(_tokenAddress).safeTransfer(msg.sender, _amount);
    }

    // ============ USER ACTIONS ============

    /**
     * @notice Supply ERC20 liquidity and earn interest.
     */
    function deposit(bytes32 _marketId, uint256 _amount) external onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        _accrueInterest(_marketId);
        Market storage market = markets[_marketId];
        market.token.safeTransferFrom(msg.sender, address(this), _amount);
        userDeposits[msg.sender][_marketId] += _amount;
        market.totalSupply += _amount;
        emit Deposit(msg.sender, _marketId, _amount);
    }

    /**
     * @notice Supply native ETH into the protocol.
     */
    function depositETH(bytes32 _marketId) external payable onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (msg.value == 0) revert InvalidAmount();
        Market storage market = markets[_marketId];
        if (address(market.token) != wethAddress) revert InvalidTokenAddress();
        _accrueInterest(_marketId);
        IWETH(wethAddress).deposit{value: msg.value}();
        userDeposits[msg.sender][_marketId] += msg.value;
        market.totalSupply += msg.value;
        emit Deposit(msg.sender, _marketId, msg.value);
    }

    /**
     * @notice Withdraw previously supplied liquidity.
     */
    function withdraw(bytes32 _marketId, uint256 _amount) external onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        _accrueInterest(_marketId);
        if (userDeposits[msg.sender][_marketId] < _amount) revert InsufficientDepositBalance();
        if (!canWithdraw(msg.sender, _marketId, _amount)) revert UnsafePosition();
        Market storage market = markets[_marketId];
        userDeposits[msg.sender][_marketId] -= _amount;
        market.totalSupply -= _amount;
        market.token.safeTransfer(msg.sender, _amount);
        emit Withdraw(msg.sender, _marketId, _amount);
    }

    /**
     * @notice Borrow assets from a specific market pool.
     */
    function borrow(bytes32 _marketId, uint256 _amount) external onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        _accrueInterest(_marketId);
        Market storage market = markets[_marketId];
        if (market.token.balanceOf(address(this)) < _amount) revert InsufficientTotalSupply();
        if (!canBorrow(msg.sender, _marketId, _amount)) revert UnsafePosition();
        userBorrows[msg.sender][_marketId] += _amount;
        market.totalBorrow += _amount;
        market.totalSupply -= _amount; 
        market.token.safeTransfer(msg.sender, _amount);
        emit Borrow(msg.sender, _marketId, _amount);
    }

    /**
     * @notice Repay an outstanding borrow position.
     */
    function repay(bytes32 _marketId, uint256 _amount) external onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        _accrueInterest(_marketId);
        Market storage market = markets[_marketId];
        if (userBorrows[msg.sender][_marketId] < _amount) revert InsufficientBorrowBalance();
        market.token.safeTransferFrom(msg.sender, address(this), _amount);
        userBorrows[msg.sender][_marketId] -= _amount;
        market.totalBorrow -= _amount;
        market.totalSupply += _amount;
        emit Repay(msg.sender, _marketId, _amount);
    }

    /**
     * @notice Forced liquidation of a user account in default.
     */
    function liquidate(address _user, bytes32 _debtMarketId, uint256 _amount) external nonReentrant whenNotPaused onlyActiveMarket(_debtMarketId) {
        if (_amount == 0) revert InvalidAmount();
        _accrueInterest(_debtMarketId);
        if (userBorrows[_user][_debtMarketId] < _amount) revert InsufficientBorrowToLiquidate();
        if (!isLiquidatable(_user)) revert PositionNotLiquidatable();
        uint256 collateralValueUSD = (_amount * getPrice(address(markets[_debtMarketId].token)) * (BASIS_POINTS + LIQUIDATION_PENALTY)) / (BASIS_POINTS);
        bytes32 collateralMid = findBestCollateral(_user);
        if (collateralMid == bytes32(0)) revert NoCollateralToSeize();
        uint256 collateralPrice = getPrice(address(markets[collateralMid].token));
        uint256 amountToSeize = (collateralValueUSD) / collateralPrice;
        if (userDeposits[_user][collateralMid] < amountToSeize) revert InsufficientCollateral();
        userBorrows[_user][_debtMarketId] -= _amount;
        markets[_debtMarketId].totalBorrow -= _amount;
        markets[_debtMarketId].totalSupply += _amount;
        userDeposits[_user][collateralMid] -= amountToSeize;
        markets[collateralMid].totalSupply -= amountToSeize;
        markets[_debtMarketId].token.safeTransferFrom(msg.sender, address(this), _amount);
        markets[collateralMid].token.safeTransfer(msg.sender, amountToSeize);
        emit Liquidate(msg.sender, _user, _debtMarketId, amountToSeize);
    }

    /**
     * @notice Processes a collateral deposit via an authorized offline signature.
     */
    function depositWithSignature(
        address _user, 
        bytes32 _marketId, 
        uint256 _amount, 
        uint256 _deadline, 
        bytes calldata _signature
    ) external onlyActiveMarket(_marketId) nonReentrant whenNotPaused {
        if (_amount == 0) revert InvalidAmount();
        _validateSignature(_user, _marketId, _amount, _deadline, _signature);
        _accrueInterest(_marketId);
        markets[_marketId].token.safeTransferFrom(_user, address(this), _amount);
        userDeposits[_user][_marketId] += _amount;
        markets[_marketId].totalSupply += _amount;
        emit Deposit(_user, _marketId, _amount);
    }

    // ============ INTERNAL ============

    /**
     * @notice Internal validation for meta-transactions.
     * @dev Author: Agustin Acosta. Explicitly clears stack from parameters.
     */
    function _validateSignature(
        address _user, 
        bytes32 _marketId, 
        uint256 _amount, 
        uint256 _deadline, 
        bytes calldata _signature
    ) internal {
        if (block.timestamp > _deadline) revert SignatureExpired();
        bytes32 structHash = keccak256(abi.encode(_marketId, _amount, users[_user].nonce, _deadline));
        bytes32 h = MessageHashUtils.toEthSignedMessageHash(structHash);
        if (ECDSA.recover(h, _signature) != _user) revert InvalidSignature();
        users[_user].nonce++;
    }

    /**
     * @notice Applies time-weighted interest to market pools.
     */
    function _accrueInterest(bytes32 _marketId) internal {
        Market storage market = markets[_marketId];
        uint256 timeDelta = block.timestamp - market.lastAccrualTime;
        if (timeDelta > 0 && market.totalBorrow > 0) {
            uint256 utilization = (market.totalBorrow * 1e18) / (market.totalSupply + market.totalBorrow);
            uint256 borrowRate;
            if (utilization <= market.kink) {
                borrowRate = market.baseRate + (utilization * market.slope1 / 1e18);
            } else {
                uint256 normalRate = market.baseRate + (market.kink * market.slope1 / 1e18);
                uint256 excessUtilization = utilization - market.kink;
                borrowRate = normalRate + (excessUtilization * market.slope2 / 1e18);
            }
            uint256 interest = (market.totalBorrow * borrowRate * timeDelta) / (365 days * 1e18);
            market.totalBorrow += interest;
            market.totalSupply += (interest * (BASIS_POINTS - RESERVE_FACTOR)) / BASIS_POINTS;
        }
        market.lastAccrualTime = block.timestamp;
    }

    /**
     * @notice Retrieves current price for an asset.
     */
    function getPrice(address _tokenAddress) public view returns (uint256) {
        uint256 price = oracle.getPrice(_tokenAddress);
        if (price == 0) revert InvalidPrice();
        return price;
    }

    /**
     * @notice Summarizes user collateral value weighted by risk factors.
     */
    function getAccountCollateralValue(address _user) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < supportedMarkets.length; i++) {
            bytes32 mId = supportedMarkets[i];
            total += (userDeposits[_user][mId] * getPrice(address(markets[mId].token)) * markets[mId].collateralFactor) / (1e18 * BASIS_POINTS);
        }
        return total;
    }

    /**
     * @notice Summarizes user value weighted by liquidation thresholds.
     */
    function getAccountLiquidationValue(address _user) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < supportedMarkets.length; i++) {
            bytes32 mId = supportedMarkets[i];
            total += (userDeposits[_user][mId] * getPrice(address(markets[mId].token)) * markets[mId].liquidationThreshold) / (1e18 * BASIS_POINTS);
        }
        return total;
    }

    /**
     * @notice Aggregates gross debt value of a user across all markets.
     */
    function getAccountDebtValue(address _user) public view returns (uint256) {
        uint256 total = 0;
        for (uint256 i = 0; i < supportedMarkets.length; i++) {
            bytes32 mId = supportedMarkets[i];
            total += (userBorrows[_user][mId] * getPrice(address(markets[mId].token))) / 1e18;
        }
        return total;
    }

    /**
     * @notice Evaluates if an account is eligible for liquidation.
     */
    function isLiquidatable(address _user) public view returns (bool) {
        uint256 debtValue = getAccountDebtValue(_user);
        return debtValue > 0 && getAccountLiquidationValue(_user) < debtValue;
    }

    /**
     * @notice Simulates result of a withdrawal.
     */
    function canWithdraw(address _user, bytes32 _marketId, uint256 _amount) public view returns (bool) {
        uint256 debtValue = getAccountDebtValue(_user);
        if (debtValue == 0) return true;
        uint256 projectedValue = 0;
        for (uint256 i = 0; i < supportedMarkets.length; i++) {
            bytes32 mId = supportedMarkets[i];
            uint256 currentBalance = userDeposits[_user][mId];
            if (mId == _marketId) currentBalance = currentBalance > _amount ? currentBalance - _amount : 0;
            projectedValue += (currentBalance * getPrice(address(markets[mId].token)) * markets[mId].collateralFactor) / (1e18 * BASIS_POINTS);
        }
        return projectedValue >= debtValue;
    }

    /**
     * @notice Simulates result of a borrow operation.
     */
    function canBorrow(address _user, bytes32 _marketId, uint256 _amount) public view returns (bool) {
        uint256 currentCollateralValue = getAccountCollateralValue(_user);
        uint256 newDebtValue = getAccountDebtValue(_user) + (_amount * getPrice(address(markets[_marketId].token))) / 1e18;
        return currentCollateralValue >= newDebtValue;
    }

    /**
     * @notice Locates the asset with the highest USD market value for a user.
     */
    function findBestCollateral(address _user) public view returns (bytes32) {
        bytes32 topMarketId; uint256 maxUSDValue = 0;
        for (uint256 i = 0; i < supportedMarkets.length; i++) {
            bytes32 activeMarketId = supportedMarkets[i];
            uint256 currentUSDValue = (userDeposits[_user][activeMarketId] * getPrice(address(markets[activeMarketId].token))) / 1e18;
            if (currentUSDValue > maxUSDValue) { maxUSDValue = currentUSDValue; topMarketId = activeMarketId; }
        }
        return topMarketId;
    }

    /**
     * @notice Returns list of active market IDs.
     */
    function getSupportedMarkets() external view returns (bytes32[] memory) { return supportedMarkets; }
    /**
     * @notice Returns security nonce for a specific user.
     */
    function getUserNonce(address _userAddress) external view returns (uint256) { return users[_userAddress].nonce; }
    /**
     * @notice Detailed configuration info for a market.
     */
    function getMarketInfo(bytes32 _marketId) external view returns (Market memory) { return markets[_marketId]; }
}