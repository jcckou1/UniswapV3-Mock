// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "@prb/math/PRBMathUD60x18.sol";
import "./FixedPoint96.sol";

library LiquidityMath {
    function getLiquidityForAmount0(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount0)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        //处理溢出
        // uint256 intermediate = PRBMathUD60x18.mulDiv(sqrtPriceAX96, sqrtPriceBX96, FixedPoint96.Q96);
        // liquidity = uint128(PRBMathUD60x18.mulDiv(amount0, intermediate, sqrtPriceBX96 - sqrtPriceAX96));
        //可能会溢出
         uint256 intermediate = uint256(sqrtPriceAX96) * uint256(sqrtPriceBX96) / FixedPoint96.Q96;
        liquidity = uint128(uint256(amount0) * intermediate / (sqrtPriceBX96 - sqrtPriceAX96));
    }

    function getLiquidityForAmount1(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint256 amount1)
        internal
        pure
        returns (uint128 liquidity)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
//可能会溢出
        liquidity = uint128(uint256(amount1) * FixedPoint96.Q96 / (sqrtPriceBX96 - sqrtPriceAX96));
    }

    // A/B为价格上下限
    function getLiquidityForAmounts(
        uint160 sqrtPriceX96,
        uint160 sqrtPriceAX96,
        uint160 sqrtPriceBX96,
        uint256 amount0,
        uint256 amount1
    ) internal pure returns (uint128 liquidity) {
        //判断上下限
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }
        //如果当前价格小于范围
        if (sqrtPriceX96 <= sqrtPriceAX96) {
            liquidity = getLiquidityForAmount0(sqrtPriceAX96, sqrtPriceBX96, amount0);
        } else if (sqrtPriceX96 <= sqrtPriceBX96) {
            uint128 liquidity0 = getLiquidityForAmount0(sqrtPriceX96, sqrtPriceBX96, amount0);
            uint128 liquidity1 = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceX96, amount1);
            //在价格范围内时，选择较小的流动性提供
            liquidity = liquidity0 < liquidity1 ? liquidity0 : liquidity1;
        } else {
            liquidity = getLiquidityForAmount1(sqrtPriceAX96, sqrtPriceBX96, amount1);
        }
    }
    function addLiquidity(uint128 x, int128 y)
        internal
        pure
        returns (uint128 z)
    {
        if (y < 0) {
            z = x - uint128(-y);
        } else {
            z = x + uint128(y);
        }
    }
}
