//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

interface IUniswapV3SwapCallback {
    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes memory data) external;
}
