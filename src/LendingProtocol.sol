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
     * @notice Validates the signature's expiration and nonce.
     * @param _sigData The signature metadata (nonce, deadline).
     */
    modifier onlyValidSignature(SignatureData calldata _sigData) {
        if(_sigData.deadline < block.timestamp) revert SignatureExpired();
        if(_sigData.nonce != userNonces[msg.sender]) revert InvalidNonce();
        _;
        userNonces[msg.sender]++;
    }

    /// @notice Raised when an operation is attempted with an amount of zero.
    error InvalidAmount();
    /// @notice Raised when a liquidator attempts to repay more than the user's current borrow balance.
    error InsufficientBorrowToLiquidate();
    /// @notice Raised when a liquidation is attempted on a healthy position (ratio >= threshold).
    error PositionNotLiquidatable();
    /// @notice Raised when no suitable collateral token can be found for the user.
    error NoCollateralToSeize();
    /// @notice Raised when the borrower doesn't have enough collateral in the selected token.
    error InsufficientCollateral();
    /// @notice Raised when a signature has passed its deadline.
    error SignatureExpired();
    /// @notice Raised when a signature uses an incorrect or already used nonce.
    error InvalidNonce();
    /// @notice Raised when the cryptographic signature recovery does not match the expected signer.
    error InvalidSignature();

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

    /**
     * @notice Deposits tokens into the protocol using a cryptographic signature for validation.
     * @dev Follows the Checks-Effects-Interactions (CEI) pattern. Uses ECDSA for signature verification.
     * @param _token The address of the token to deposit.
     * @param _amount The amount of tokens to deposit.
     * @param _sigData The signature and metadata (nonce, deadline).
     */
    function depositWithSignature(
        address _token, 
        uint256 _amount, 
        SignatureData calldata _sigData
    ) 
        external 
        nonReentrant 
        whenNotPaused 
        onlyActiveMarket(_token) 
        onlyValidSignature(_sigData) 
    {
        if(_amount == 0) revert InvalidAmount();

        // Verify signature
        bytes32 messageHash = keccak256(abi.encodePacked(
            "deposit",
            _token,
            _amount,
            _sigData.nonce,
            _sigData.deadline
        ));
        
        bytes32 ethSignedMessageHash = MessageHashUtils.toEthSignedMessageHash(messageHash);
        address signer = ethSignedMessageHash.recover(_sigData.signature);
        if(signer != msg.sender) revert InvalidSignature();
        if(signer == address(0)) revert InvalidSignature();

        // --- Effects ---
        userDeposits[msg.sender][_token] += _amount;
        users[msg.sender].totalDeposited += _amount;
        users[msg.sender].lastUpdateTime = block.timestamp;
        users[msg.sender].isActive = true;

        markets[_token].totalSupply += _amount;

        emit Deposit(msg.sender, _token, _amount);

        // --- Interactions ---
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
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

    /**
     * @notice Liquidates an unhealthy position by repaying debt and seizing collateral at a discount.
     * @dev Follows the Checks-Effects-Interactions (CEI) pattern to prevent reentrancy and uses custom errors for gas efficiency.
     * @param _user The address of the borrower whose position is being liquidated.
     * @param _token The address of the borrowed token being repaid.
     * @param _amount The amount of debt to repay.
     */
    function liquidate(address _user, address _token, uint256 _amount) external nonReentrant whenNotPaused onlyActiveMarket(_token) {
        if(_amount == 0) revert InvalidAmount();
        if(userBorrows[_user][_token] < _amount) revert InsufficientBorrowToLiquidate();
        if(!isLiquidatable(_user)) revert PositionNotLiquidatable();
        
        uint256 collateralToSeize = (_amount * (BASIS_POINTS + LIQUIDATION_PENALTY)) / BASIS_POINTS;
        
        address collateralToken = findBestCollateral(_user);
        if(collateralToken == address(0)) revert NoCollateralToSeize();
        if(userDeposits[_user][collateralToken] < collateralToSeize) revert InsufficientCollateral();
        
        // --- Effects ---
        userBorrows[_user][_token] -= _amount;
        users[_user].totalBorrowed -= _amount;
        markets[_token].totalBorrow -= _amount;

        userDeposits[_user][collateralToken] -= collateralToSeize;
        users[_user].totalDeposited -= collateralToSeize;
        markets[collateralToken].totalSupply -= collateralToSeize;
        
        users[_user].lastUpdateTime = block.timestamp;

        if(users[_user].totalBorrowed == 0 && users[_user].totalDeposited == 0){
            users[_user].isActive = false;
        }

        // --- Interactions ---
        IERC20(_token).safeTransferFrom(msg.sender, address(this), _amount);
        IERC20(collateralToken).safeTransfer(msg.sender, collateralToSeize);
        
        emit Liquidate(msg.sender, _user, _token, _amount);
    }

    /**
     * @notice Checks if a user's position is below the liquidation threshold.
     * @param _user The address to check.
     * @return bool True if the position can be liquidated.
     */
    function isLiquidatable(address _user) public view returns (bool) {
        uint256 ratio = getCollateralizationRatio(_user);
        return ratio < LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Searches for the best collateral token based on the highest adjusted collateral value.
     * @dev Iterates through all markets to find the asset where the user has the most value (amount * factor).
     * @param _user The address of the borrower.
     * @return address The address of the token with the highest collateral value, or address(0) if none found.
     */
    function findBestCollateral(address _user) internal view returns (address) {
        address bestToken = address(0);
        uint256 bestValue = 0;
        
        uint256 length = supportedTokens.length;
        for(uint256 i = 0; i < length; i++){
            address token = supportedTokens[i];
            if(markets[token].isActive && userDeposits[_user][token] > 0){
                uint256 value = (userDeposits[_user][token] * markets[token].collateralFactor) / BASIS_POINTS;
                if(value > bestValue){
                    bestValue = value;
                    bestToken = token;
                }
            }
        }
        return bestToken;
    }

    function canWithdraw(address _user, address _token, uint256 _amount) public view returns (bool) {
        uint256 currentRatio = getCollateralizationRatio(_user);
        if(currentRatio == type(uint256).max) return true;
        
        uint256 newCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        for(uint i = 0; i < supportedTokens.length; i++){
            address supportedToken = supportedTokens[i];
            if(markets[supportedToken].isActive){
                uint256 depositAmount = userDeposits[_user][supportedToken];
                uint256 borrowAmount = userBorrows[_user][supportedToken];
                
                if(supportedToken == _token){
                    depositAmount = depositAmount > _amount ? depositAmount - _amount : 0;
                }

                if(depositAmount > 0){
                    newCollateralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }

                if(borrowAmount > 0){
                    totalBorrowValue += (borrowAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }
            }
        }

        if(totalBorrowValue == 0) return true;

        uint256 newRatio = (newCollateralValue * BASIS_POINTS) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Checks if a user is eligible to borrow a specific amount of tokens based on their collateral.
     * @dev Simulates the resulting global collateralization ratio to ensure it stays above the liquidation threshold.
     * @param _user The address of the borrower.
     * @param _token The address of the token being borrowed.
     * @param _amount The amount of the token requested.
     * @return bool True if the borrow maintains a healthy position, false otherwise.
     */
    function canBorrow(address _user, address _token, uint256 _amount) public view returns (bool) {
        uint256 currentRatio = getCollateralizationRatio(_user);
        
        // Even if there is no current debt, we must simulate the new borrow to ensure health
        uint256 totalCollateralValue = 0;
        uint256 totalBorrowValue = 0;

        uint256 length = supportedTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address supportedToken = supportedTokens[i];
            if (markets[supportedToken].isActive) {
                uint256 depositAmount = userDeposits[_user][supportedToken];
                uint256 borrowAmount = userBorrows[_user][supportedToken];

                if (supportedToken == _token) {
                    borrowAmount += _amount;
                }

                if (depositAmount > 0) {
                    totalCollateralValue += (depositAmount * markets[supportedToken].collateralFactor) / BASIS_POINTS;
                }

                if (borrowAmount > 0) {
                    totalBorrowValue += borrowAmount;
                }
            }
        }

        if (totalBorrowValue == 0) return true;

        uint256 newRatio = (totalCollateralValue * BASIS_POINTS) / totalBorrowValue;
        return newRatio >= LIQUIDATION_THRESHOLD;
    }

    /**
     * @notice Calculates the current overall collateralization ratio for a user's entire portfolio.
     * @param _user The address of the user to check.
     * @return uint256 The global ratio in basis points, or type(uint256).max if the user has no debt.
     */
    function getCollateralizationRatio(address _user) public view returns (uint256) {
        uint256 totalCollateral = 0;
        uint256 totalDebt = 0;

        uint256 length = supportedTokens.length;
        for (uint256 i = 0; i < length; i++) {
            address token = supportedTokens[i];
            
            if (markets[token].isActive) {
                uint256 depositAmount = userDeposits[_user][token];
                uint256 borrowAmount = userBorrows[_user][token];

                if (depositAmount > 0) {
                    totalCollateral += (depositAmount * markets[token].collateralFactor) / BASIS_POINTS;
                }
                
                if (borrowAmount > 0) {
                    totalDebt += borrowAmount;
                }
            }
        }

        if (totalDebt == 0) return type(uint256).max;
        
        return (totalCollateral * BASIS_POINTS) / totalDebt;
    }

    function pause() external onlyOwner{
        _pause();
    }

    function unpause() external onlyOwner{
        _unpause();
    }

}