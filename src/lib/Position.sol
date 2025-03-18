//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

//头寸,用户在某个价格区间提供的一对代币和流动性量
library Position {
    struct Info {
        uint128 liquidity; //用户在某个价格区间提供的流动性
    }

    //更新头寸的流动性，self代表要更新的某个tick或头寸的流动性状态
    function update(Info storage self, uint128 liquidityDelta) internal {
        uint128 liquidityBefore = self.liquidity;
        uint128 liquidityAfter = liquidityBefore + liquidityDelta;

        self.liquidity = liquidityAfter;
    }

    //索引特定用户的特定tick的流动性
    function get(mapping(bytes32 => Info) storage self, address owner, int24 lowerTick, int24 upperTick)
        internal
        view
        returns (Position.Info storage position)
    {
        //用这三个值去索引特定用户的特定tick的流动性
        position = self[keccak256(abi.encodePacked(owner, lowerTick, upperTick))];
    }
}
