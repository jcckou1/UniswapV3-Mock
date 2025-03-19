// SPDX-License-Identifier: BUSL-1.1
pragma solidity ^0.8.14;

import "../../lib/solidity-bytes-utils/contracts/BytesLib.sol";

//用来将字节数组的某一部分转换成 uint24 类型，对于bytesLib的补充
library BytesLibExt {
    function toUint24(bytes memory _bytes, uint256 _start) internal pure returns (uint24) {
        require(_bytes.length >= _start + 3, "toUint24_outOfBounds");
        uint24 tempUint;

        assembly {
            tempUint := mload(add(add(_bytes, 0x3), _start))
        }

        return tempUint;
    }
}

library Path {
    /**
     * 计算路径中的池数量；
     * 确定路径是否有多个池；
     * 从路径中提取第一个池的参数；
     * 在路径中进行到下一对；
     * 解码第一个池的参数。
     */
    uint256 private constant ADDR_SIZE = 20;
    uint256 private constant TICKSPACING_SIZE = 3;
    uint256 private constant NEXT_OFFSET = ADDR_SIZE + TICKSPACING_SIZE; //是下一个代币地址的偏移量，一个代币地址长度加上tick间距
    uint256 private constant POP_OFFSET = NEXT_OFFSET + ADDR_SIZE; //是池键的偏移量,因为一个池有两个代币，所以再加一个地址长度
    uint256 private constant MULTIPLE_POOLS_MIN_LENGTH = POP_OFFSET + NEXT_OFFSET; //是包含2个或更多池的路径的最小长度

    using BytesLibExt for bytes;
    using BytesLib for bytes;
    //计算路径中的池数量

    function numPools(bytes memory path) internal pure returns (uint256) {
        return (path.length - ADDR_SIZE) / NEXT_OFFSET;
    }

    //检查路径中是否有多个池，是否大于MULTIPLE_POOLS_MIN_LENGTH
    function hasMultiplePools(bytes memory path) internal pure returns (bool) {
        return path.length >= MULTIPLE_POOLS_MIN_LENGTH;
    }

    //该函数简单地返回编码为字节的第一个"代币地址 + tick间距 + 代币地址"段
    function getFirstPool(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(0, POP_OFFSET);
    }

    //当我们遍历路径并丢弃已处理的池时，我们将使用下一个函数，我们移除的是"代币地址 + tick间距"，而不是完整的池参数，
    //因为我们需要另一个代币地址来计算下一个池地址
    function skipToken(bytes memory path) internal pure returns (bytes memory) {
        return path.slice(NEXT_OFFSET, path.length - NEXT_OFFSET);
    }

    //解码路径中第一个池的参数
    function decodeFirstPool(bytes memory path)
        internal
        pure
        returns (address tokenIn, address tokenOut, uint24 tickSpacing)
    {
        tokenIn = path.toAddress(0);
        tickSpacing = path.toUint24(ADDR_SIZE);
        tokenOut = path.toAddress(NEXT_OFFSET);
    }
}
