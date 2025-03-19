// SPDX-License-Identifier: GPL-2.0-or-later
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Pool.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./lib/Path.sol";
import "./lib/PoolAddress.sol";
import "./lib/TickMath.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";

/**
 * 这个设计有一个重要的限制：由于quote调用Pool合约的swap函数，而swap函数不是纯函数或视图函数（因为它修改合约状态），quote也不能是纯函数或视图函数。
 * 这意味着用户不能直接从其他合约中调用quote函数，因为外部合约不能调用非视图函数。
 * 这就是为什么我们需要一个单独的Quoter合约，它实现了相同的逻辑但作为一个独立的合约。
 */
//向前端展示展示交换金额

contract UniswapV3Quoter {
    using Path for bytes;

    //方便回调函数选择不同代币地址，选择不同池子，以及不同用户
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    struct QuoteSingleParams {
        address tokenIn; //池地址换为两个代币地址和tick间距
        address tokenOut;
        uint24 tickSpacing;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    struct QuoteParams {
        address tokenIn;
        address tokenOut;
        uint24 fee;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
        int24 tickLimit;
    }

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    //模拟一次真实交换，输出金额用于展示
    function quoteSingle(QuoteSingleParams memory params) internal returns (uint256 amountOut) {
        bool zeroForOne = params.tokenIn < params.tokenOut;

        try
            getPool(params.tokenIn, params.tokenOut, params.tickSpacing).swap(
                address(0),
                zeroForOne,
                params.amountIn,
                params.sqrtPriceLimitX96,
                abi.encode(CallbackData({token0: params.tokenIn, token1: params.tokenOut, payer: msg.sender}))
            )
        returns (int256 amount0, int256 amount1) {
            amountOut = uint256(-(zeroForOne ? amount1 : amount0));
        } catch (bytes memory reason) {
            return abi.decode(reason, (uint256));
        }
    }

    function quote(bytes memory path, uint256 amountIn) external returns (uint256 amountOut) {
        (address tokenIn, address tokenOut, uint24 tickSpacing) = path.decodeFirstPool();

        amountOut = quoteSingle(
            QuoteSingleParams({
                tokenIn: tokenIn,
                tokenOut: tokenOut,
                tickSpacing: tickSpacing,
                amountIn: amountIn,
                sqrtPriceLimitX96: 0
            })
        );
    }

    function uniswapV3SwapCallback(int256 amount0Delta, int256 amount1Delta, bytes memory data) external view {
        address pool = abi.decode(data, (address));

        uint256 amountOut = amount0Delta > 0 ? uint256(-amount1Delta) : uint256(-amount0Delta);

        (uint160 sqrtPriceX96After, int24 tickAfter) = IUniswapV3Pool(pool).slot0();

        assembly {
            let ptr := mload(0x40) //读取下一个可用内存槽的指针（EVM中的内存以32字节为一个槽组织）
            mstore(ptr, amountOut) //在那个内存槽，mstore(ptr, amountOut)写入amountOut
            mstore(add(ptr, 0x20), sqrtPriceX96After) //在amountOut之后写入sqrtPriceX96After
            mstore(add(ptr, 0x40), tickAfter) //在sqrtPriceX96After之后写入tickAfter
            revert(ptr, 96) //revert(ptr, 96)回滚调用并返回地址ptr（我们上面写入的数据的开始）处的96字节数据（我们写入内存的值的总长度）
        }
    }

    function getPool(address tokenA, address tokenB, uint24 tickSpacing) internal view returns (IUniswapV3Pool pool) {
        (tokenA, tokenB) = tokenA < tokenB ? (tokenA, tokenB) : (tokenB, tokenA);
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, tokenA, tokenB, tickSpacing));
    }
}
