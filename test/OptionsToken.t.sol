// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {DiscountExerciseParams, DiscountExercise, BaseExercise} from "../src/exercise/DiscountExercise.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {BalancerOracle} from "../src/oracles/BalancerOracle.sol";
import {IOracle} from "../src/interfaces/IOracle.sol";
import {MockBalancerTwapOracle} from "./mocks/MockBalancerTwapOracle.sol";

contract OptionsTokenTest is Test {
    using FixedPointMathLib for uint256;

    uint16 constant PRICE_MULTIPLIER = 5000; // 0.5
    uint56 constant ORACLE_SECS = 30 minutes;
    uint56 constant ORACLE_AGO = 2 minutes;
    uint128 constant ORACLE_MIN_PRICE = 1e17;
    uint56 constant ORACLE_LARGEST_SAFETY_WINDOW = 24 hours;
    uint256 constant ORACLE_INIT_TWAP_VALUE = 1e19;
    uint256 constant ORACLE_MIN_PRICE_DENOM = 10000;
    uint256 constant MAX_SUPPLY = 1e27; // the max supply of the options token & the underlying token

    address owner;
    address tokenAdmin;
    address[] feeRecipients_;
    uint256[] feeBPS_;

    OptionsToken optionsToken;
    DiscountExercise exerciser;
    IOracle[] oracles;
    MockBalancerTwapOracle balancerTwapOracle;
    TestERC20 paymentToken;
    address underlyingToken;

    function setUp() public {
        // set up accounts
        owner = makeAddr("owner");
        tokenAdmin = makeAddr("tokenAdmin");

        feeRecipients_ = new address[](2);
        feeRecipients_[0] = makeAddr("feeRecipient");
        feeRecipients_[1] = makeAddr("feeRecipient2");

        feeBPS_ = new uint256[](2);
        feeBPS_[0] = 1000; // 10%
        feeBPS_[1] = 9000; // 90%

        // deploy contracts
        paymentToken = new TestERC20();
        underlyingToken = address(new TestERC20());

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("TIT Call Option Token", "oTIT", tokenAdmin);
        optionsToken.transferOwnership(owner);

        address[] memory tokens = new address[](2);
        tokens[0] = address(paymentToken);
        tokens[1] = underlyingToken;

        balancerTwapOracle = new MockBalancerTwapOracle(tokens);
        console.log(tokens[0], tokens[1]);
        oracles.push(new BalancerOracle(balancerTwapOracle, underlyingToken, owner, ORACLE_SECS, ORACLE_AGO, ORACLE_MIN_PRICE));

        exerciser =
        new DiscountExercise(optionsToken, owner, IERC20(address(paymentToken)), IERC20(underlyingToken), oracles, PRICE_MULTIPLIER, feeRecipients_, feeBPS_);

        TestERC20(underlyingToken).mint(address(exerciser), 1e20 ether);

        // add exerciser to the list of options
        vm.startPrank(owner);
        optionsToken.setExerciseContract(address(exerciser), true);
        vm.stopPrank();

        // set up contracts
        balancerTwapOracle.setTwapValue(ORACLE_INIT_TWAP_VALUE);
        paymentToken.approve(address(exerciser), type(uint256).max);
    }

    function test_onlyTokenAdminCanMint(uint256 amount, address hacker) public {
        vm.assume(hacker != tokenAdmin);

        // try minting as non token admin
        vm.startPrank(hacker);
        vm.expectRevert(OptionsToken.OptionsToken__NotTokenAdmin.selector);
        optionsToken.mint(address(this), amount);
        vm.stopPrank();

        // mint as token admin
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // verify balance
        assertEqDecimal(optionsToken.balanceOf(address(this)), amount, 18);
    }

    function test_exerciseHappyPath(uint256 amount, address recipient) public {
        amount = bound(amount, 100, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        (uint256 paymentAmount,,,) = optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));

        // verify options tokens were transferred
        assertEqDecimal(optionsToken.balanceOf(address(this)), 0, 18, "user still has options tokens");
        assertEqDecimal(optionsToken.totalSupply(), 0, 18, "option tokens not burned");

        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        uint256 paymentFee1 = expectedPaymentAmount.mulDivDown(feeBPS_[0], 10000);
        uint256 paymentFee2 = expectedPaymentAmount - paymentFee1;
        assertEqDecimal(paymentToken.balanceOf(feeRecipients_[0]), paymentFee1, 18, "fee recipient 1 didn't receive payment tokens");
        assertEqDecimal(paymentToken.balanceOf(feeRecipients_[1]), paymentFee2, 18, "fee recipient 2 didn't receive payment tokens");
        assertEqDecimal(paymentAmount, expectedPaymentAmount, 18, "exercise returned wrong value");
    }

    function test_exerciseMinPrice(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // set TWAP value such that the strike price is below the oracle's minPrice value
        balancerTwapOracle.setTwapValue(ORACLE_MIN_PRICE - 1);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_MIN_PRICE);
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(bytes4(keccak256("BalancerOracle__BelowMinPrice()")));
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_priceMultiplier(uint256 amount, uint256 multiplier) public {
        amount = bound(amount, 1, MAX_SUPPLY / 2);

        vm.prank(owner);
        exerciser.setMultiplier(10000); // full price

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount * 2);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE);
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        (uint256 paidAmount,,,) = optionsToken.exercise(amount, address(this), address(exerciser), abi.encode(params));

        // update multiplier
        multiplier = bound(multiplier, 1000, 20000);
        vm.prank(owner);
        exerciser.setMultiplier(multiplier);

        // exercise options tokens
        uint256 newPrice = oracles[0].getPrice().mulDivUp(multiplier, 10000);
        uint256 newExpectedPaymentAmount = amount.mulWadUp(newPrice);
        params.maxPaymentAmount = newExpectedPaymentAmount;

        paymentToken.mint(address(this), newExpectedPaymentAmount);
        (uint256 newPaidAmount,,,) = optionsToken.exercise(amount, address(this), address(exerciser), abi.encode(params));
        // verify payment tokens were transferred
        assertEqDecimal(paymentToken.balanceOf(address(this)), 0, 18, "user still has payment tokens");
        assertEq(newPaidAmount, paidAmount.mulDivUp(multiplier, 10000), "incorrect discount");
    }

    function test_exerciseHighSlippage(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount - 1, deadline: type(uint256).max});
        vm.expectRevert(DiscountExercise.Exercise__SlippageTooHigh.selector);
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_exerciseTwapOracleNotReady(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // update oracle params
        // such that the TWAP window becomes (block.timestamp - ORACLE_LARGEST_SAFETY_WINDOW - ORACLE_SECS, block.timestamp - ORACLE_LARGEST_SAFETY_WINDOW]
        // which is outside of the largest safety window
        vm.prank(owner);
        BalancerOracle(address(oracles[0])).setParams(ORACLE_SECS, ORACLE_LARGEST_SAFETY_WINDOW, ORACLE_MIN_PRICE);

        // exercise options tokens which should fail
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(BalancerOracle.BalancerOracle__TWAPOracleNotReady.selector);
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_exercisePastDeadline(uint256 amount, address recipient, uint256 deadline) public {
        amount = bound(amount, 0, MAX_SUPPLY);
        deadline = bound(deadline, 0, block.timestamp - 1);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: deadline});
        if (amount != 0) {
            vm.expectRevert(DiscountExercise.Exercise__PastDeadline.selector);
        }
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }

    function test_exerciseNotOToken(uint256 amount, address recipient) public {
        amount = bound(amount, 0, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(BaseExercise.Exercise__NotOToken.selector);
        exerciser.exercise(address(this), amount, recipient, abi.encode(params));
    }

    function test_exerciseNotExerciseContract(uint256 amount, address recipient) public {
        amount = bound(amount, 1, MAX_SUPPLY);

        // mint options tokens
        vm.prank(tokenAdmin);
        optionsToken.mint(address(this), amount);

        // set option inactive
        vm.prank(owner);
        optionsToken.setExerciseContract(address(exerciser), false);

        // mint payment tokens
        uint256 expectedPaymentAmount = amount.mulWadUp(ORACLE_INIT_TWAP_VALUE.mulDivUp(PRICE_MULTIPLIER, ORACLE_MIN_PRICE_DENOM));
        paymentToken.mint(address(this), expectedPaymentAmount);

        // exercise options tokens which should fail
        DiscountExerciseParams memory params = DiscountExerciseParams({maxPaymentAmount: expectedPaymentAmount, deadline: type(uint256).max});
        vm.expectRevert(OptionsToken.OptionsToken__NotExerciseContract.selector);
        optionsToken.exercise(amount, recipient, address(exerciser), abi.encode(params));
    }
}
