// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import "forge-std/Test.sol";
import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {IThenaPair} from "../src/interfaces/IThenaPair.sol";
import {DiscountExercise, IOracle} from "../src/exercise/DiscountExercise.sol";
import {OptionsToken} from "../src/OptionsToken.sol";

import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";

struct Params {
    IThenaPair pair;
    address token;
    address owner;
    uint32 secs;
    uint128 minPrice;
}

contract ThenaOracleTest is Test {
    using stdStorage for StdStorage;

    string BSC_RPC_URL = vm.envString("BSC_RPC_URL");

    address POOL_1_ADDRESS = 0x6BE6A437A1172e6C220246eCB3A92a45AF9f0Cbc; // wbnb/usdt
    address POOL_2_ADDRESS = 0x5134729Cd5a5b40336BC3CA71349f2c108718428; // hbr/wbnb
    address TARGET_TOKEN_1_ADDRESS = 0xbb4CdB9CBd36B01bD1cBaEBF2De08d9173bc095c; // wbnb
    address UNDERLYING_TOKEN_ADDRESS = 0x42c95788F791a2be3584446854c8d9BB01BE88A9;  // hbr
    address PAYMENT_TOKEN_ADDRESS = 0x55d398326f99059fF775485246999027B3197955; // usdt

    uint256 MULTIPLIER_DENOM = 10000;
    uint256 PRICE_MULTIPLIER = 10000;

    address owner;
    address tokenAdmin;
    address[] feeRecipients_;
    uint256[] feeBPS_;
    OptionsToken optionsToken;
    DiscountExercise exerciser;
    IOracle[] oracles;

    uint256 bscFork;

    Params oracle1Params;
    Params oracle2Params;

    function setUp() public {
        oracle1Params = Params(IThenaPair(POOL_1_ADDRESS), TARGET_TOKEN_1_ADDRESS, address(this), 30 minutes, 1000);
        oracle2Params = Params(IThenaPair(POOL_2_ADDRESS), UNDERLYING_TOKEN_ADDRESS, address(this), 30 minutes, 1000);

        bscFork = vm.createSelectFork(BSC_RPC_URL);

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

        address implementation = address(new OptionsToken());
        ERC1967Proxy proxy = new ERC1967Proxy(implementation, "");
        optionsToken = OptionsToken(address(proxy));
        optionsToken.initialize("TIT Call Option Token", "oTIT", tokenAdmin);

        ThenaOracle oracle1 = new ThenaOracle(
            oracle1Params.pair,
            oracle1Params.token,
            oracle1Params.owner,
            oracle1Params.secs,
            oracle1Params.minPrice
        );
        ThenaOracle oracle2 = new ThenaOracle(
            oracle2Params.pair,
            oracle2Params.token,
            oracle2Params.owner,
            oracle2Params.secs,
            oracle2Params.minPrice
        );
        oracles.push(oracle1);
        oracles.push(oracle2);

        exerciser = new DiscountExercise(optionsToken, owner, IERC20(PAYMENT_TOKEN_ADDRESS), IERC20(UNDERLYING_TOKEN_ADDRESS), oracles, PRICE_MULTIPLIER, feeRecipients_, feeBPS_);
        optionsToken.setExerciseContract(address(exerciser), true);

        optionsToken.transferOwnership(owner);
    }

    function test_priceThroughWBNB() public {
        uint256 output = exerciser.getPaymentAmount(1e18);
        emit log_named_decimal_uint("Oracle price", output, 18);
    }
}
