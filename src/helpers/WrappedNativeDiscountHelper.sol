// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {DiscountExercise, DiscountExerciseParams} from "../exercise/DiscountExercise.sol";
import {IWETH} from "../interfaces/IWETH.sol";
import {OptionsToken} from "../OptionsToken.sol";

contract WrappedNativeHelper {
    receive() external payable {}

    function exerciseUsingNative(
        OptionsToken optionsToken,
        DiscountExercise discountExercise,
        uint256 amount,
        address recipient,
        uint256 deadline
    ) external payable returns (uint256) {
        IWETH weth = IWETH(address(discountExercise.paymentToken()));

        weth.deposit{value: msg.value}();
        optionsToken.transferFrom(msg.sender, address(this), amount);
        
        DiscountExerciseParams memory params = DiscountExerciseParams({
            maxPaymentAmount: msg.value,
            deadline: deadline
        });

        weth.approve(address(discountExercise), msg.value);
        (uint paymentAmount,,,) = optionsToken.exercise(amount, recipient, address(discountExercise), abi.encode(params));

        uint256 leftover = msg.value - paymentAmount;
        if (leftover > 0) {
            IWETH(address(discountExercise.paymentToken())).withdraw(leftover);
            (bool success, ) = payable(msg.sender).call{value: leftover}("");
            require(success, "WrappedNativeHelper: exerciseUsingNative: transfer failed");
        }
        return paymentAmount;
    }
}
