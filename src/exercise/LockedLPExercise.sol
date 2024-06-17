// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {OptionsToken} from "../OptionsToken.sol";

import {IOracle} from "../interfaces/IOracle.sol";
import {IRouter} from "../test/interfaces/IRouter.sol";
import {IPairFactory} from "../interfaces/IPairFactory.sol";
import {IPair} from "../interfaces/IPair.sol";

import {SablierStreamCreator} from "./Sablier/SablierStreamCreator.sol";

struct LockedExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
}

/// @title Options Token Locked LP Price Exercise Contract
/// @author @adamo
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to the market
/// price. Those underlying token are paired 50:50 with additional payment tokens
/// to create an LP which is timelocked for release to the user
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract LockedExercise is BaseExercise, SablierStreamCreator {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();
    error Exercise__InvalidMultiplier();
    error Exercise__InvalidOracle();

    /// Events
    event Exercised(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetRouter(address indexed newRouter);
    event SetPair(IERC20 indexed paymentToken, IERC20 indexed underlyingToken, IPair indexed pair);
    event ExerciseLp(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount, uint256 lpTokenAmount, uint256 lockDuration, uint256 streamId);

    /// Constants

    /// @notice The denominator for converting the multiplier into a decimal number.
    /// i.e. multiplier uses 4 decimals.
    uint256 internal constant MULTIPLIER_DENOM = 10000;

    /// Immutable parameters

    /// @notice The token paid by the options token holder during redemption
    IERC20 public immutable paymentToken;

    /// @notice The underlying token purchased during redemption
    IERC20 public immutable underlyingToken;

    /// Storage variables

    /// @notice The router for adding liquidity
    IRouter public router;

    /// @notice The pair for transferring LP tokens to Sablier
    IPair public pair;

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice the discount given during exercising with locking to the LP
    uint256 public maxMultiplier = 3000; // 70% discount
    uint256 public minMultiplier = 8000; // 20% discount

    uint256 public minLpLockDuration = 1 weeks;
    uint256 public maxLpLockDuration = 1 years;

    constructor(
        OptionsToken oToken_,
        address owner_,
        IERC20 paymentToken_,
        IERC20 underlyingToken_,
        IOracle oracle_,
        address router_,
        address[] memory feeRecipients_,
        uint256[] memory feeBPS_
    ) BaseExercise(oToken_, feeRecipients_, feeBPS_) Owned(owner_) {
        paymentToken = paymentToken_;
        underlyingToken = underlyingToken_;

        _setOracle(oracle_);
        _setRouter(router_);
        _setPair(paymentToken_, underlyingToken_);

        emit SetOracle(oracle_);
        emit SetRouter(router_);
    }

    /// External functions

    function exerciseLp(uint256 amount, address recipient, uint256 multiplier, bytes memory params) external returns (uint256, uint256) {
        return _exerciseLp(amount, recipient, multiplier, lockDuration, params);
    }

    /// Internal functions

    function _exerciseLp(uint256 amount, address recipient, uint256 multiplier, bytes memory params)
        internal
        returns (uint256 paymentAmount, uint256 lpAmount)
    {
        // ===============
        //  === CHECKS ===
        // ===============

        // decode params
        LockedExerciseParams memory _params = abi.decode(params, (LockedExerciseParams));

        if (block.timestamp > _params.deadline) revert Exercise__PastDeadline();

        // multiplier validity
        if (multiplier > minMultiplier || multiplier < maxMultiplier) {
            revert Exercise__InvalidMultiplier();
        }

        // =========================
        //  === PRICE & DISCOUNT ===
        // =========================

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM);

        // get payment amount
        paymentAmount = amount.mulWadUp(price);
        if (paymentAmount > _params.maxPaymentAmount) revert Exercise__SlippageTooHigh();

        // ======================
        //  === PROTOCOL FEES ===
        // ======================

        // @note distributeFeesFrom requires the user to sign a transaction, or multiple
        // transactions, in order to send the payment token to an array of feeRecipients; then later
        // in this function the user is required to sign another transaction to send *more* payment
        // tokens to pair up with the underlying token to form an LP pair. Is there a way to collect
        // all the paymentTokens in a single transfer and then do the fee distribution & LP pair side
        // separately??
        distributeFeesFrom(paymentAmount, paymentToken, from); // transfer payment tokens from user to the set receivers

        // ==================
        //  === CREATE LP ===
        // ==================

        // calculate second side (payment token) amount of the LP that user needs to supply
        (uint256 underlyingReserve, uint256 paymentReserve) = IRouter(router).getReserves(underlyingToken, paymentToken, false);
        paymentAmountToAddLiquidity = (_amount * paymentReserve) / underlyingReserve;

        // Approvals for router
        underlyingToken.safeTransfer(router, amount);
        paymentToken.safeTransferFrom(msg.sender, router, paymentAmountToAddLiquidity;)

        // Create LP
        (,, lpTokenAmount) =
            router.addLiquidity(underlyingToken, paymentToken, false, amount, paymentAmountToAddLiquidity, 1, 1, address(this), block.timestamp);

        // ================
        //  === LOCK LP ===
        // ================

        // get the lock duration using the chosen multiplier
        uint256 lockDuration = getLockDurationForLpDiscount(multiplier);

        // Create Sablier timelock
        uint256 streamId = createTimelock(lpTokenAmount, lockDuration, pair, recipient);

        emit ExerciseLp(msg.sender, recipient, amount, paymentAmount, lpTokenAmount, lockDuration, streamId);
    }

    /// Owner functions

    /// @notice Sets the oracle contract. Only callable by the owner.
    /// @param oracle_ The new oracle contract
    function setOracle(IOracle oracle_) external onlyOwner {
        _setOracle(oracle_);
    }

    function _setOracle(IOracle oracle_) internal {
        (address paymentToken_, address underlyingToken_) = oracle_.getTokens();
        if (paymentToken_ != address(paymentToken) || underlyingToken_ != address(underlyingToken)) {
            revert Exercise__InvalidOracle();
        }
        oracle = oracle_;
        emit SetOracle(oracle_);
    }

    /// @notice Sets the router contract. Only callable by the owner.
    /// @param oracle_ The new router contract
    function setRouter(address router_) external onlyOwner {
        _setRouter(router_);
    }

    function _setRouter(address router_) internal {
        // *** need to check router validity here ***
        router = router_;
        emit SetRouter(router_);
    }

    /// @notice Retrieves the pair contract address by calling getPair, and sets the pair on this contract
    function setPair(IERC20 paymentToken_, IERC20 underlyingToken_) external onlyOwner {
        _setPair(IERC20 paymentToken_, IERC20 underlyingToken_);
    }

    function _setPair(IERC20 paymentToken_, IERC20 underlyingToken_) internal {
        pair = IPairFactory.getPair(address(paymentToken_), address(underlyingToken_, false)); // get & set pair address
        emit SetPair(paymentToken_, underlyingToken_, pair);
    }

    /// View functions

    function getLockDurationForLpDiscount(uint256 multiplier_) public view returns (uint256 duration) {
        (int256 slope, int256 intercept) = getSlopeInterceptForLpDiscount();
        duration = SignedMath.abs(slope * int256(multiplier_) + intercept); // SignedMath needs to be imported
    }

    function getSlopeInterceptForLpDiscount() public view returns (int256 slope, int256 intercept) {
        slope = int256(maxLpLockDuration - minLpLockDuration) / (int256(maxMultiplier) - int256(minMultiplier));
        intercept = int256(minLpLockDuration) - (slope * int256(minMultiplier));
    }
}
