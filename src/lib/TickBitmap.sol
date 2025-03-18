//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./BitMath.sol";

library TickBitmap {
    /**
     * wordPos用于索引一个uint256的整数（块）
     * 而这个块可以看作一个256位的数组，每个位是一个元素（bitPos）
     * 每个bitPos代表一个tick
     * 所以一个wordPos可以索引到一个有256个tick的块，节省空间
     *
     */
    //确定tick位置
    function position(int24 tick) private pure returns (int16 wordPos, uint8 bitPos) {
        //用位图来储存把位图想象成一个 无限长的位数组，每256位为一块
        //>>8 右移8位，相当于十进制的中除以256，向下取整
        wordPos = int16(tick >> 8);
        //取余数计算是具体多少位，因为每256代表一个块，所以余数代表是具体哪一位
        bitPos = uint8(uint24(tick % 256));
        /**
         * tick = 85176
         * word = tick >> 8 = 332
         * bit= tick % 256 = 184
         * 所以数值为85176的tick在我们的存储中是第332个块的第184位
         * 以次来确定tick的信息，如流动性等
         */
    }

    //翻转标志0 => 1，1 => 0
    function flipTick(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing //每个tick的间隔，如为2时，就只有0，2，4，6，8等的tick，确保tick不能太密集
    ) internal {
        require(tick % tickSpacing == 0); //确保tick是tickSpacing的倍数
        (int16 wordPos, uint8 bitPos) = position(tick / tickSpacing); //
        //把1左移bitPos位则uint256的一个数中，第bitPos位为1，其余位为0
        uint256 mask = 1 << bitPos;
        //翻转位状态，self代表位图，self[wordPos]代表第wordPos个块，^=代表异或操作，即翻转位状态
        //把第wordPos个块的第bitPos位翻转
        self[wordPos] ^= mask;
    }

    //找到在当前块中有流动性的下一个tick
    function nextInitializedTickWithInOneWord(
        mapping(int16 => uint256) storage self,
        int24 tick,
        int24 tickSpacing,
        bool lte //方向标志
    ) internal view returns (int24 next, bool initialized) {
        //compressed是压缩后的tick，即在满足tickSpacing的倍数的情况下，压缩后的tick
        int24 compressed = tick / tickSpacing;
        //true向右（卖x），false向左（买x）
        if (lte) {
            //卖出x
            //获取位置
            (int16 wordPos, uint8 bitPos) = position(compressed);
            /**
             * 1 << bitPos：在 bitPos 位置生成一个 1
             * 如bitPos = 5 → 0b00100000
             * (1 << bitPos) - 1：生成 bitPos 右边全 1
             * 0b00100000 - 1 → 0b00011111
             * 结果：0b00011111 + 0b00100000 → 0b00111111
             */
            //制作掩码，目的是为了把当前位置的位和当前位置的右边的位都置为0，来屏蔽更小位的tick
            uint256 mask = (1 << bitPos) - 1 + (1 << bitPos);
            /**
             * word: 0b00111111
             * mask: 0b00100000
             * masked: 0b00100000
             * 此时masked从又到左找到第一个1，即找到下一个tick
             */
            //将制作好的掩码与当前位置的块进行与&操作
            uint256 masked = self[wordPos] & mask;
            //如果当前masked至少有1个1，即有tick，initialized为true
            initialized = masked != 0;
            next = initialized
                /**
                 * BitMath.mostSignificantBit(masked)，masked中从右到左找到的第一个1
                 * bitPos - BitMath.mostSignificantBit(masked) 计算当前bitPos到下一个tick的距离
                 * compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked))),减去偏移量，
                 * 相当于把当前位置移动到下一个tick的位置
                 * 最后乘上tickSpacing，使其变为tickSpacing的倍数
                 */
                ? (compressed - int24(uint24(bitPos - BitMath.mostSignificantBit(masked)))) * tickSpacing
                //返回下一个字中最左边的位——这将允许我们在另一个循环周期中搜索该字中的初始化tick
                : (compressed - int24(uint24(bitPos))) * tickSpacing;
        } else {
            //买入x
            (int16 wordPos, uint8 bitPos) = position(compressed + 1);
            uint256 mask = ~((1 << bitPos) - 1); //～取反操作
            uint256 masked = self[wordPos] & mask;

            initialized = masked != 0;
            next = initialized
                ? (compressed + 1 + int24(uint24((BitMath.leastSignificantBit(masked) - bitPos)))) * tickSpacing
                : (compressed + 1 + int24(uint24((type(uint8).max - bitPos)))) * tickSpacing;
        }
    }
}
