// SPDX-License-Identifier: MIT
pragma solidity 0.8.24;

import {MockToken} from "./MockToken.sol";
import {IERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "../lib/openzeppelin-contracts/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "../lib/openzeppelin-contracts/contracts/utils/ReentrancyGuard.sol";
import {Pausable} from "../lib/openzeppelin-contracts/contracts/utils/Pausable.sol";
import {Ownable} from "../lib/openzeppelin-contracts/contracts/access/Ownable.sol";
import {ECDSA} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/ECDSA.sol";
import {MessageHashUtils} from "../lib/openzeppelin-contracts/contracts/utils/cryptography/MessageHashUtils.sol";

/**
 * @title Advanced Lending & Borrowing Protocol
 * @author Agustin Acosta
 * @notice This contract implements the core logic for a decentralized lending and borrowing platform, 
 * focusing on collateralized debt positions and interest rate dynamics.
 * @dev Inherits from OpenZeppelin standards to ensure security through ReentrancyGuard, Pausable, and Ownable models.
 * Uses SafeERC20 for robust token interactions and ECDSA for cryptographic verification.
 */
contract LendingProtocol is ReentrancyGuard, Pausable, Ownable {
    using SafeERC20 for IERC20;
    using ECDSA for bytes32;
    using MessageHashUtils for bytes32;

    // Events
    /**
     * @notice Emitted when a new market is added to the protocol.
     * @param token The address of the token being added as a market.
     * @param collateralFactor The collateral factor assigned to the token (expressed in basis points or fixed-point).
     */
    event MarketAdded(address indexed token, uint256 collateralFactor);

    /**
     * @notice Emitted when an existing market's parameters are updated.
     * @param token The address of the token being updated.
     * @param collateralFactor The new collateral factor assigned to the token.
     */
    event MarketUpdated(address indexed token, uint256 collateralFactor);

    /**
     * @notice Emitted when a user deposits tokens into a market.
     * @param user The address of the user making the deposit.
     * @param token The address of the token being deposited.
     * @param amount The amount of tokens deposited.
     */
    event Deposit(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user withdraws tokens from a market.
     * @param user The address of the user making the withdrawal.
     * @param token The address of the token being withdrawn.
     * @param amount The amount of tokens withdrawn.
     */
    event Withdraw(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user borrows tokens from a market.
     * @param user The address of the user taking the loan.
     * @param token The address of the token being borrowed.
     * @param amount The amount of tokens borrowed.
     */
    event Borrow(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user repays a debt.
     * @param user The address of the user repaying the debt.
     * @param token The address of the token being repaid.
     * @param amount The amount of tokens repaid.
     */
    event Repay(address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when a user's position is liquidated.
     * @param liquidator The address of the liquidator.
     * @param user The address of the user being liquidated.
     * @param token The address of the token involved in the liquidation.
     * @param amount The amount of tokens liquidated.
     */
    event Liquidate(address indexed liquidator, address indexed user, address indexed token, uint256 amount);

    /**
     * @notice Emitted when interest rates for a market are updated.
     * @param token The address of the token whose rates were updated.
     * @param supplyRate The new supply interest rate.
     * @param borrowRate The new borrow interest rate.
     */
    event RatesUpdated(address indexed token, uint256 supplyRate, uint256 borrowRate);

    modifier onlyActiveMarket(address token){
        require(markets[token].isActive, "Market is not active");
        _;
    }

    /**
     * @notice Represents the protocol state for an individual user.
     * @dev State variables are tracked to calculate interest and health factor.
     */
    struct User {
        uint256 totalDeposited;
        uint256 totalBorrowed;
        uint256 lastUpdateTime;
        bool isActive;
    }

    /**
     * @notice Represents the configuration and state of a specific asset market.
     * @dev Contains parameters for interest rates and risk management (collateral factor).
     */
    struct Market {
        IERC20 token;
        uint256 totalSupply;
        uint256 totalBorrow;
        uint256 supplyRate;
        uint256 borrowRate;
        uint256 collateralFactor;
        bool isActive;
    }

    /**
     * @notice Container for cryptographic signature data used in meta-transactions or permit-style logic.
     * @param nonce Replay protection counter.
     * @param deadline Unix timestamp after which the signature is invalid.
     * @param signature The ECDSA signature bytes.
     */
    struct SignatureData {
        uint256 nonce;
        uint256 deadline;
        bytes signature;
    }

    address[] public supportedTokens;
    uint256 public constant LIQUIDATION_THRESHOLD = 8000; // 80% in basis point
    uint256 public constant LIQUIDATION_PENALTY = 500; // 5% in basis point
    uint256 public constant BASIS_POINTS = 10000;

    // States Variables
    /**
     * @notice Mapping of user addresses to their global protocol state.
     */
    mapping(address => User) public users;

    /**
     * @notice Mapping of user address to token address to current deposit balance.
     */
    mapping(address => mapping(address => uint256)) public userDeposits;

    /**
     * @notice Mapping of user address to token address to current borrow balance.
     */
    mapping(address => mapping(address => uint256)) public userBorrows;

    /**
     * @notice Mapping of token addresses to their corresponding market configuration and state.
     */
    mapping(address => Market) public markets;

    /**
     * @notice Tracking nonces for signature-based operations per user to prevent reattacks.
     */
    mapping(address => uint256) public userNonces;

    /**
     * @notice Protocol constructor setting the initial owner.
     * @dev msg.sender is set as the initial owner via OpenZeppelin's Ownable.
     */
    constructor() Ownable(msg.sender) {}


    function addMarket(address _token, uint256 _collateralFactor, uint256 _initialSupplyRate, uint256 _initialBorrowRate) external onlyOwner {
        require(_token != address(0), "Invalid token address");
        require(_collateralFactor > 0 && _collateralFactor <= BASIS_POINTS, "Invalid collateral factor");
        require(!markets[_token].isActive, "Market already exists");

        supportedTokens.push(_token);
        markets[_token] = Market({
            token: IERC20(_token),
            totalSupply: 0,
            totalBorrow: 0,
            supplyRate: _initialSupplyRate,
            borrowRate: _initialBorrowRate,
            collateralFactor: _collateralFactor,
            isActive: true
        });

        emit MarketAdded(_token, _collateralFactor);
    }

    function updateMarket(address _token, uint256 _collateralFactor, uint256 _supplyRate, uint256 _borrowRate) external onlyOwner onlyActiveMarket(_token){
        require(_collateralFactor > 0 && _collateralFactor <= BASIS_POINTS, "Invalid collateral factor");

        markets[_token].collateralFactor = _collateralFactor;
        markets[_token].supplyRate = _supplyRate;
        markets[_token].borrowRate = _borrowRate;

        emit MarketUpdated(_token, _collateralFactor);
        emit RatesUpdated(_token, _supplyRate, _borrowRate);
    }


    function deposit(address _token, uint256 _amount) external onlyActiveMarket(_token) nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        userDeposits[msg.sender][_token] += _amount;
        users[msg.sender].totalDeposited += _amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[_token].totalSupply += _amount;

        emit Deposit(msg.sender, _token, _amount);
    }

    function withdraw(address _token, uint256 _amount) external onlyActiveMarket(_token) nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        require(userDeposits[msg.sender][_token] >= _amount, "Insufficient deposit balance");
        require(canWithdraw(msg.sender, _token, _amount), "Withdrawal would make position unhealthy");

        userDeposits[msg.sender][_token] -= _amount;
        users[msg.sender].totalDeposited -= _amount;
        users[msg.sender].lastUpdateTime = block.timestamp;

        if(users[msg.sender].totalDeposited == 0){
            users[msg.sender].isActive = false;
        }

        markets[_token].totalSupply -= _amount;

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Withdraw(msg.sender, _token, _amount);
    }

    function borrow(address _token, uint256 _amount) external onlyActiveMarket(_token) nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        require(markets[_token].isActive, "Market is not active");
        require(markets[_token].totalSupply >= _amount, "Insufficient total supply");
        require(canBorrow(msg.sender, _token, _amount), "Borrow would make position unhealthy");

        userBorrows[msg.sender][_token] += _amount;
        users[msg.sender].totalBorrowed += _amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[_token].totalBorrow += _amount;

        IERC20(_token).safeTransfer(msg.sender, _amount);

        emit Borrow(msg.sender, _token, _amount);
    }

    function repay(address _token, uint256 _amount) external onlyActiveMarket(_token) nonReentrant whenNotPaused {
        require(_amount > 0, "Amount must be greater than 0");
        require(userBorrows[msg.sender][_token] >= _amount, "Insufficient borrow balance");

        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);

        userBorrows[msg.sender][_token] -= _amount;
        users[msg.sender].totalBorrowed -= _amount;
        users[msg.sender].lastUpdateTime = block.timestamp;

        if(users[msg.sender].totalBorrowed == 0){
            users[msg.sender].isActive = false;
        }
        
        markets[_token].totalBorrow -= _amount;

        emit Repay(msg.sender, _token, _amount);
    }




    function pause() external onlyOwner{
        _pause();
    }

    function unpause() external onlyOwner{
        _unpause();
    }

}