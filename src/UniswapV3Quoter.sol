//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./UniswapV3Pool.sol";

/**
 * 这个设计有一个重要的限制：由于quote调用Pool合约的swap函数，而swap函数不是纯函数或视图函数（因为它修改合约状态），quote也不能是纯函数或视图函数。
 * swap修改状态，quote也是如此，即使不是在Quoter合约中。
 * 但我们将quote视为一个getter，一个只读取合约数据的函数。
 * 这种不一致意味着当调用quote时，EVM将使用CALL操作码而不是STATICCALL。
 * 这不是一个大问题，因为Quoter在交换回调中回滚，而回滚会重置调用期间修改的状态——这保证了quote不会修改Pool合约的状态（不会发生实际交易）。
 * 这个问题带来的另一个不便是，从客户端库（Ethers.js、Web3.js等）调用quote将触发一个交易。
 * 为了解决这个问题，我们需要强制库进行静态调用。我们将在本里程碑的后面看到如何在Ethers.js中做到这一点。
 */
//向前端展示展示交换金额

contract UniswapQuoter {
    struct QuoteSingleParams {
        address tokenIn; //池地址换为两个代币地址和tick间距
        address tokenOut;
        uint24 tickSpacing;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    address public immutable factory;

    constructor(address factory_) {
        factory = factory_;
    }

    //模拟一次真实交换，输出金额用于展示
    function quoteSingle(QuoteSingleParams memory params)
        public
        returns (uint256 amountOut, uint160 sqrtPriceX96After, int24 tickAfter)
    {
        IUniswapV3Pool pool = getPool(params.tokenIn, params.tokenOut, params.tickSpacing);

        bool zeroForOne = params.tokenIn < params.tokenOut;

        try pool.swap(
            address(this),
            zeroForOne,
            params.amountIn,
            params.sqrtPriceLimitX96 == 0
                ? (zeroForOne ? TickMath.MIN_SQRT_RATIO + 1 : TickMath.MAX_SQRT_RATIO - 1)
                : params.sqrtPriceLimitX96,
            abi.encode(address(pool))
        ) {} catch (bytes memory reason) {
            return abi.decode(reason, (uint256, uint160, int24)); //预期回调，返回模拟计算结果
        }
    }

    function quote(bytes memory path, uint256 amountIn)
        public
        returns (
            uint256 amountOut,
            uint160[] memory sqrtPriceX96AfterList, //交换后的值
            int24[] memory tickAfterList
        )
    {
        sqrtPriceX96AfterList = new uint160[](path.numPools());
        tickAfterList = new int24[](path.numPools());

        uint256 i = 0;
        while (true) {
            (address tokenIn, address tokenOut, uint24 tickSpacing) = path.decodeFirstPool();

            (uint256 amountOut_, uint160 sqrtPriceX96After, int24 tickAfter) = quoteSingle(
                QuoteSingleParams({
                    tokenIn: tokenIn,
                    tokenOut: tokenOut,
                    tickSpacing: tickSpacing,
                    amountIn: amountIn,
                    sqrtPriceLimitX96: 0
                })
            );

            sqrtPriceX96AfterList[i] = sqrtPriceX96After;
            tickAfterList[i] = tickAfter;
            amountIn = amountOut_;
            i++;
            //如果路径中还有更多的池，则重复；否则返回
            if (path.hasMultiplePools()) {
                path = path.skipToken();
            } else {
                amountOut = amountIn;
                break;
            }
        }
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory data) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter) = IUniswapV3pool(pool).slot0();

        assembly {
            let ptr := mload(0x40) //读取下一个可用内存槽的指针（EVM中的内存以32字节为一个槽组织）
            mstore(ptr, amountOut) //在那个内存槽，mstore(ptr, amountOut)写入amountOut
            mstore(add(ptr, 0x20), sqrtPriceX96After) //在amountOut之后写入sqrtPriceX96After
            mstore(add(ptr, 0x40), tickAfter) //在sqrtPriceX96After之后写入tickAfter
            revert(ptr, 96) //revert(ptr, 96)回滚调用并返回地址ptr（我们上面写入的数据的开始）处的96字节数据（我们写入内存的值的总长度）
        }
    }

    function getPool(address token0, address token1, uint24 tickSpacing) internal view returns (UniswapV3Pool pool) {
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, tickSpacing));
    }
}
