// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.20;

import "./FixedPoint96.sol";
import "@prb/math/PRBMathUD60x18.sol";

library Math {
    /// @notice Calculates amount0 delta between two prices
    /// TODO: round down when removing liquidity
    function calcAmount0Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount0)
    {
        //对价格进行排序，以确保在相减时不会发生下溢
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        require(sqrtPriceAX96 > 0);
        //根据公式，我们将其乘以价格的差值，并除以较大的价格。之后，我们再除以较小的价格。
        //除法的顺序并不重要，但我们想要进行两次除法，因为价格的乘法可能会溢出
        amount0 = divRoundingUp(
            mulDivRoundingUp(
                (uint256(liquidity) << FixedPoint96.RESOLUTION), (sqrtPriceBX96 - sqrtPriceAX96), sqrtPriceBX96
            ),
            sqrtPriceAX96
        );
    }

    /// @notice Calculates amount1 delta between two prices
    /// TODO: round down when removing liquidity
    function calcAmount1Delta(uint160 sqrtPriceAX96, uint160 sqrtPriceBX96, uint128 liquidity)
        internal
        pure
        returns (uint256 amount1)
    {
        if (sqrtPriceAX96 > sqrtPriceBX96) {
            (sqrtPriceAX96, sqrtPriceBX96) = (sqrtPriceBX96, sqrtPriceAX96);
        }

        amount1 = mulDivRoundingUp(liquidity, (sqrtPriceBX96 - sqrtPriceAX96), FixedPoint96.Q96);
    }

    function getNextSqrtPriceFromInput(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn, bool zeroForOne)
        internal
        pure
        returns (uint160 sqrtPriceNextX96)
    {
        //判断是哪个方向的交易
        sqrtPriceNextX96 = zeroForOne
            ? getNextSqrtPriceFromAmount0RoundingUp(sqrtPriceX96, liquidity, amountIn)
            : getNextSqrtPriceFromAmount1RoundingDown(sqrtPriceX96, liquidity, amountIn);
    }

    function getNextSqrtPriceFromAmount0RoundingUp(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn)
        internal
        pure
        returns (uint160)
    {
        //liquidity左移96位，放大精度以避免精度损失
        uint256 numerator = uint256(liquidity) << FixedPoint96.RESOLUTION;
        uint256 product = amountIn * sqrtPriceX96;

        // If product doesn't overflow, use the precise formula.
        if (product / amountIn == sqrtPriceX96) {
            uint256 denominator = numerator + product;
            if (denominator >= numerator) {
                return uint160(mulDivRoundingUp(numerator, sqrtPriceX96, denominator));
            }
        }

        // If product overflows, use a less precise formula.
        //在上一个return可能会溢出的情概况下，使用此return，精度更低
        return uint160(divRoundingUp(numerator, (numerator / sqrtPriceX96) + amountIn));
    }

    function getNextSqrtPriceFromAmount1RoundingDown(uint160 sqrtPriceX96, uint128 liquidity, uint256 amountIn)
        internal
        pure
        returns (uint160)
    {
        return sqrtPriceX96 + uint160((amountIn << FixedPoint96.RESOLUTION) / liquidity);
    }

    function mulDivRoundingUp(uint256 a, uint256 b, uint256 denominator) internal pure returns (uint256 result) {
        result = PRBMath.mulDiv(a, b, denominator);

        //mulmod是一个Solidity函数，它将两个数（a和b）相乘，将结果除以denominator
        if (mulmod(a, b, denominator) > 0) {
            require(result < type(uint256).max);
            result++;
        }
    }

    function divRoundingUp(uint256 numerator, uint256 denominator) internal pure returns (uint256 result) {
        assembly {
            result := add(div(numerator, denominator), gt(mod(numerator, denominator), 0))
        }
    }
}
