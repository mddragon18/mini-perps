//SPDX-License-Identifier: MIT
pragma solidity 0.8.28;

import {ERC4626} from '@openzeppelin/contracts/token/ERC20/extensions/ERC4626.sol';
import {IERC20} from '@openzeppelin/contracts/token/ERC20/IERC20.sol';
import {ERC20} from '@openzeppelin/contracts/token/ERC20/ERC20.sol';

contract LiquidityPool is ERC4626 {
    constructor(IERC20 _asset) ERC4626(_asset) ERC20("LiquidityProvider","LP") {}

    // Liquidity providers should be able to deposit the underlying token and receive the LP token.
    //
}