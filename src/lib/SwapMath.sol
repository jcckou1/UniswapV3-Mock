//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./Math.sol";

library SwapMath {
    function computeSwapStep(
        uint160 sqrtPriceCurrentX96,
        uint160 sqrtPriceTargetX96, //目标价格的平方根，表示价格可能移动的终点
        uint128 liquidity,
        uint256 amountRemaining
    )
        internal
        pure
        returns (
            uint160 sqrtPriceNextX96,
            uint256 amountIn, //用于查看一次调用处理了多少输入数量
            uint256 amountOut
        )
    {
        bool zeroForOne = sqrtPriceCurrentX96 >= sqrtPriceTargetX96;
        //判断方向
        amountIn = zeroForOne
            ? Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity)
            : Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceTargetX96, liquidity);

        //判断当前范围的流动性是否能满足交换
        if (amountRemaining >= amountIn) {
            //不能的话，使用范围内所有流动性，价格发生变动
            sqrtPriceNextX96 = sqrtPriceTargetX96;
        } else {
            //可以的话在当前范围内计算价格
            sqrtPriceNextX96 =
                Math.getNextSqrtPriceFromInput(sqrtPriceCurrentX96, liquidity, amountRemaining, zeroForOne);
        }
        //获得下一个价格以后在当前范围内计算
        amountIn = Math.calcAmount0Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);
        amountOut = Math.calcAmount1Delta(sqrtPriceCurrentX96, sqrtPriceNextX96, liquidity);
        //如果方向相反，则交换
        if (!zeroForOne) {
            (amountIn, amountOut) = (amountOut, amountIn);
        }
    }
}
