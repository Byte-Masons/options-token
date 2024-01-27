/// SPDX-License-Identifier: AGPL-3.0
pragma solidity ^0.8.13;

import {IERC20} from "oz/token/ERC20/IERC20.sol";

interface IWETH is IERC20 {
    function deposit() external payable;
    function withdraw(uint) external;
}
