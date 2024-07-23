import "forge-std/Test.sol";

import {FixedPointMathLib} from "solmate/utils/FixedPointMathLib.sol";
import {IERC20} from "oz/token/ERC20/IERC20.sol";
import {ERC1967Proxy} from "oz/proxy/ERC1967/ERC1967Proxy.sol";

import {OptionsToken} from "../src/OptionsToken.sol";
import {DiscountExerciseParams, DiscountExercise, BaseExercise} from "../src/exercise/DiscountExercise.sol";
// import {SwapProps, ExchangeType} from "../src/helpers/SwapHelper.sol";
import {TestERC20} from "./mocks/TestERC20.sol";
import {ThenaOracle} from "../src/oracles/ThenaOracle.sol";
import {MockBalancerTwapOracle} from "./mocks/MockBalancerTwapOracle.sol";

import {ReaperSwapper, MinAmountOutData, MinAmountOutKind, IVeloRouter, ISwapRouter, UniV3SwapData} from "vault-v2/ReaperSwapper.sol";

import "./Common.sol";

contract testUpgrade is Test, Common {
    address oTokenProxy = 0x3B6eA0fA8A487c90007ce120a83920fd52b06f6D;
    address oTokenImpl = 0x3bbc5c0B5c564eAD5e9586F93c67BcB307cB8CAE;
    address oTokenAdmin = 0xF29dA3595351dBFd0D647857C46F8D63Fc2e68C5;
    address oTokenOwner = 0xD4D995787D39D70F35E694dC8306D7dB863234aC; //multisig
    OptionsToken oToken;

    uint256 FORK_BLOCK = 10764064;
    string MAINNET_URL = vm.envString("MODE_RPC_URL");

    function setUp() public {
        uint256 fork = vm.createFork(MAINNET_URL, FORK_BLOCK);
        vm.selectFork(fork);

        

        OptionsToken newIMPL = new OptionsToken();
        oToken = OptionsToken(payable(oTokenProxy));
        vm.startPrank(oTokenOwner);
        oToken.initiateUpgradeCooldown(address(newIMPL));
        vm.warp(block.timestamp + 49 hours);
        oToken.upgradeTo(address(newIMPL));
    }

    function test_TADMINCANNOTMINT() public{
        vm.startPrank(oTokenAdmin);
        vm.expectRevert();
        oToken.mint(oTokenAdmin, 1000);

    }

    function test_TADMINCANNOTBURN() public{
        vm.startPrank(oTokenAdmin);
        vm.expectRevert();
        oToken.burn(0xA071E099982F584421d6982e4Eb860974D87CE26, 1000);
    }

    function test_OWNERCANMINT() public {
        vm.startPrank(oTokenOwner);
        oToken.mint(oTokenOwner, 1000);
    }

    function test_OWNERCANBURN() public {
        vm.startPrank(oTokenOwner);
        oToken.burn(0xA071E099982F584421d6982e4Eb860974D87CE26, 1000);

    }

}