
// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {Owned} from "solmate/auth/Owned.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {SafeERC20} from "oz/token/ERC20/utils/SafeERC20.sol";
import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";

import {BaseExercise} from "../exercise/BaseExercise.sol";
import {IOracle} from "../interfaces/IOracle.sol";
import {OptionsToken} from "../OptionsToken.sol";

import {IThenaRouter} from "./interfaces/IThenaRouter.sol";

struct LockedExerciseParams {
    uint256 maxPaymentAmount;
    uint256 deadline;
}

struct UserLpLock {
    uint256 lpTokens;
    uint256 unlockTime;
}

/// @title Options Token Locked LP Price Exercise Contract
/// @author @adamo
/// @notice Contract that allows the holder of options tokens to exercise them,
/// in this case, by purchasing the underlying token at a discount to a fixed
/// price set by owner, the underlying token & payment token are then deposited
/// to create an LP which is timelocked for release to the user
/// @dev Assumes the underlying token and the payment token both use 18 decimals.
contract LockedExercise is BaseExercise {
    /// Library usage
    using SafeERC20 for IERC20;
    using FixedPointMathLib for uint256;

    /// Errors
    error Exercise__SlippageTooHigh();
    error Exercise__PastDeadline();
    error Exercise__InvalidDiscount();
    error Exercise__InvalidOracle();
    error Exercise__LpNotUnlocked();

    /// Events
    event Exercised(address indexed sender, address indexed recipient, uint256 amount, uint256 paymentAmount);
    event SetOracle(IOracle indexed newOracle);
    event SetRouter(address indexed newRouter);
    event ExerciseLp();

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
    IThenaRouter public router;

    /// @notice The oracle contract that provides the current price to purchase
    /// the underlying token while exercising options (the strike price)
    IOracle public oracle;

    /// @notice the discount given during exercising with locking to the LP
    uint256 public maxLPDiscount = 200; //  User pays 20%
    uint256 public minLPDiscount = 800; //  User pays 80%

    uint256 public minLpLockDuration;
    uint256 public maxLpLockDuration;

    mapping(address => UserLpLock[]) public UserLpLocks;

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

        emit SetOracle(oracle_);
        emit SetRouter(router_);
    }

    /// External functions

    function exerciseLp(uint256 amount, address recipient, uint256 multiplier, bytes memory params) external returns (uint256, uint256) {
        return _exerciseLp(amount, recipient, multiplier, params);
    }

    function retrieveLp(uint256 lpPosition) external {
        for() {
            UserLpLocks[msg.sender]
        }
        if() {
            revert Exercise__LpNotUnlocked();
        }
    }

    /// Internal functions

    function _exerciseLp(uint256 amount, address recipient, uint256 multiplier, bytes memory params)
        internal
        returns (uint256 paymentAmount, uint256 lpAmount)
    {
        // decode params
        LockedExerciseParams memory _params = abi.decode(params, (LockedExerciseParams));
        if (block.timestamp > _params.deadline) revert Exercise__PastDeadline();

        // discount validity
        if (multiplier > minLPDiscount || multiplier < maxLPDiscount) {
            revert Exercise__InvalidDiscount();
        }

        // apply multiplier to price
        uint256 price = oracle.getPrice().mulDivUp(multiplier, MULTIPLIER_DENOM);

        paymentAmount = amount.mulWadUp(price);
        if (paymentAmount > _params.maxPaymentAmount) revert Exercise__SlippageTooHigh();

        // distributeFeesFrom() is not required if paymentToken is being paired with underlying to form LP
        // but some exercise fee for the protocol will likely be taken

        // pay() is not required as underlying tokens are being paired with the paymentToken to form LP

        // burn() is called on the oToken contract in our implementation

        (uint256 paymentAmount, uint256 paymentAmountToAddLiquidity) = getPaymentTokenAmountForExerciseLp(amount, multiplier);
        if (paymentAmount > _params.maxPaymentAmount) {
            revert Exercise__SlippageTooHigh();
        }

        // Create Lp for users (Solidly-forked DEX)
        _safeApprove(underlyingToken, router, amount);
        _safeApprove(paymentToken, router, paymentAmountToAddLiquidity);
        (,, lpTokenAmount) = router.addLiquidity(
            underlyingToken, paymentToken, false, amount, paymentAmountToAddLiquidity, 1, 1, address(this), block.timestamp
        );

        // Amount of LP tokens a user has on the exercised position & the time the LP can be retrieved
        UserLpLocks[msg.sender].push(UserLpLock(lpTokenAmount, lpUnlockTime)); // lpUnlockTime to be set above
        uint256 lpIndexPosition = UserLpLocks[msg.sender].length();

        emit ExerciseLp(msg.sender, recipient, amount, paymentAmount, lpAmount, lpIndexPosition, lpUnlockTime);

    }

    function _pay(address to, uint256 amount) internal returns (uint256 remainingAmount) {
        uint256 balance = underlyingToken.balanceOf(address(this));
        if (amount > balance) {
            underlyingToken.safeTransfer(to, balance);
            remainingAmount = amount - balance;
        } else {
            underlyingToken.safeTransfer(to, amount);
        }
        credit[to] += remainingAmount;
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

    /// View functions

    // @notice Returns the amount in paymentTokens for a given amount of options tokens required for the LP exercise lp
    /// @param _amount The amount of options tokens to exercise
    /// @param _discount The discount amount
    function getPaymentTokenAmountForExerciseLp(uint256 _amount, uint256 _discount)
        public
        view
        returns (uint256 paymentAmount, uint256 paymentAmountToAddLiquidity)
    {
        paymentAmount = getLpDiscountedPrice(_amount, _discount);
        (uint256 underlyingReserve, uint256 paymentReserve) = IRouter(router).getReserves(underlyingToken, paymentToken, false);
        paymentAmountToAddLiquidity = (_amount * paymentReserve) / underlyingReserve;
    }

    /// @notice Returns the discounted price in paymentTokens for a given amount of options tokens redeemed to veFLOW
    /// @param _amount The amount of options tokens to exercise
    /// @param _discount The discount amount
    /// @return The amount of payment tokens to pay to purchase the underlying tokens
    function getLpDiscountedPrice(uint256 _amount, uint256 _discount) public view returns (uint256) {
        return (getTimeWeightedAveragePrice(_amount) * _discount) / 100;
    }

    /// @notice Returns the average price in payment tokens over 2 hours for a given amount of underlying tokens
    /// @param _amount The amount of underlying tokens to purchase
    /// @return The amount of payment tokens
    function getTimeWeightedAveragePrice(uint256 _amount) public view returns (uint256) {
        uint256[] memory amtsOut = IPair(pair).prices(underlyingToken, _amount, twapPoints);
        uint256 len = amtsOut.length;
        uint256 summedAmount;

        for (uint256 i = 0; i < len; i++) {
            summedAmount += amtsOut[i];
        }

        return summedAmount / twapPoints;
    }
}