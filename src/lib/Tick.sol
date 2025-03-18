//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./Math.sol";

library Tick {
    /**
     * Tick,一个用于定义流动性价格的点，每个价格点是一个Tick，价格=1.0001^Tick
     * Tick = 0 时，价格是 1.0
     * Tick = 1 时，价格是 1.0001
     * Tick = -1 时，价格是 0.9999
     * 每跳一个 Tick，价格变动 0.01%。这样就能离散化价格曲线，提高交易效率。
     */
    struct Info {
        uint128 liquidityGross; //跟踪一个价格刻度的绝对流动性数量它用于确定一个价格刻度是否被翻转
        bool initialized;
        int128 liquidityNet; //它跟踪当跨越一个价格刻度时添加（在下限价格刻度的情况下）或移除（在上限价格刻度的情况下）的流动性数量
    }

    //更新某个价格点的流动性。liquidityDelta: 流动性变动值，可能是增加（正值）或减少（负值）
    function update(
        //将tick映射到对应的流动性信息，我们需要在不同价格点更新流动性
        mapping(int24 => Tick.Info) storage self,
        int24 tick,
        uint128 liquidityDelta
    ) internal returns (bool flipped) {
        Tick.Info storage tickInfo = self[tick];

        uint128 liquidityBefore = tickInfo.liquidityGross;

        uint128 liquidityAfter = LiquidityMath.addLiquidity(liquidityBefore, liquidityDelta);

        //当向空的tick添加流动性或从tick中移除全部流动性时，该标志会被设置为true, 表示该tick已被翻转
        flipped = (liquidityAfter == 0) != (liquidityBefore == 0);

        //如果tick流动性为0，则初始化
        if (liquidityBefore == 0) {
            tickInfo.initialized = true;
        }

        tickInfo.liquidityGross = liquidityAfter;
        tickInfo.liquidityNet = upper
            ? int128(int256(tickInfo.liquidityNet) - liquidityDelta)
            : int128(int256(tickInfo.liquidityNet) + liquidityDelta);
    }

    function cross(mapping(int24 => Tick.Info) storage self, int24 tick)
        internal
        view
        returns (int128 liquidityDelta)
    {
        Tick.Info storage info = self[tick];
        liquidityDelta = info.liquidityNet;
    }
}
