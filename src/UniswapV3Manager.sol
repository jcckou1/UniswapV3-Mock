//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3Pool.sol";
import "./lib/LiquidityMath.sol";
import "./lib/TickMath.sol";
import "./lib/PoolAddress.sol";
import "./lib/Path.sol";
import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
//用户与池子交互的合约

contract UniswapV3Manager {
    using Path for bytes;

    error SlippageCheckFailed(uint256, uint256);
    error TooLittleReceived(uint256);

    address public immutable factory;

    constructor(address _factory) {
        factory = _factory;
    }

    struct MintParams {
        address poolAddress;
        int24 lowerTick;
        int24 upperTick;
        uint256 amount0Desired;
        uint256 amount1Desired;
        uint256 amount0Min; //基于滑点容忍度计算的数量
        uint256 amount1Min; //基于滑点容忍度计算的数量
    }

    //单池交换参数
    struct SwapSingleParams {
        address tokenIn;
        address tokenOut;
        uint24 tickSpacing;
        uint256 amountIn;
        uint160 sqrtPriceLimitX96;
    }

    //多池交换参数
    struct SwapParams {
        bytes path;
        address recipient;
        uint256 amountIn;
        uint256 minAmountOut;
    }

    struct SwapCallbackData {
        bytes path;
        address payer; //payer是在交换中提供输入代币的地址——在多池交换过程中，我们会有不同的支付者
    }

    function mint(MintParams calldata params) public returns (uint256 amount0, uint256 amount1) {
        IUniswapV3Pool pool = IUniswapV3Pool(params.poolAddress);

        (uint160 sqrtPriceX96,) = pool.slot0();
        uint160 sqrtPriceLowerX96 = TickMath.getSqrtRatioAtTick(params.lowerTick);
        uint160 sqrtPriceUpperX96 = TickMath.getSqrtRatioAtTick(params.upperTick);

        uint128 liquidity = LiquidityMath.getLiquidityForAmounts(
            sqrtPriceX96, sqrtPriceLowerX96, sqrtPriceUpperX96, params.amount0Desired, params.amount1Desired
        );
        //向池子提供流动性
        (amount0, amount1) = pool.mint(
            msg.sender,
            params.lowerTick,
            params.upperTick,
            liquidity,
            abi.encode(IUniswapV3Pool.CallbackData({token0: pool.token0(), token1: pool.token1(), payer: msg.sender}))
        );
        //如果能提供的amount0和1太少，则回滚
        if (amount0 < params.amount0Min || amount1 < params.amount1Min) {
            revert SlippageCheckFailed(amount0, amount1);
        }
    }

    //多池交换
    function swap(SwapParams memory params) public returns (uint256 amountOut) {
        address payer = msg.sender;
        bool hasMultiplePools;
        
        while (true) {
            hasMultiplePools = params.path.hasMultiplePools();

            params.amountIn = _swap(
                params.amountIn,
                hasMultiplePools ? address(this) : params.recipient,
                0,
                SwapCallbackData({path: params.path.getFirstPool(), payer: payer})
            );

            //判断是否需要继续处理路径中的下一个池或返回
            if (hasMultiplePools) {
                payer = address(this);
                params.path = params.path.skipToken();
            } else {
                amountOut = params.amountIn;
                break;
            }
        }

        //新的滑点保护
        if (amountOut < params.minAmountOut) {
            revert TooLittleReceived(amountOut);
        }
    }

    function uniswapV3MintCallback(uint256 amount0, uint256 amount1, bytes calldata data) external {
        //解码出特定信息data
        IUniswapV3Pool.CallbackData memory extra = abi.decode(data, (IUniswapV3Pool.CallbackData));
        //此时的msg.sender是Pool合约，因为是Pool回调了这个函数，所以这段意思为用户将代币转给Pool合约
        IERC20(extra.token0).transferFrom(extra.payer, msg.sender, amount0);
        IERC20(extra.token1).transferFrom(extra.payer, msg.sender, amount1);
    }

    function uniswapV3SwapCallback(int256 amount0, int256 amount1, bytes calldata data_) public {
        SwapCallbackData memory decoded = abi.decode(data_, (SwapCallbackData));
        (address tokenIn, address tokenOut,) = decoded.path.decodeFirstPool(); //获取解码数据

        bool zeroForOne = tokenIn < tokenOut; //token从小到大排序

        int256 amount = zeroForOne ? amount0 : amount1;

        /**
         * 1、如果支付者是当前合约（这在进行连续交换时会发生），它会从当前合约的余额中将代币转移到下一个池（调用此回调的池）。
         * 2、如果支付者是不同的地址（发起交换的用户），它会从用户的余额中转移代币。
         */
        if (decoded.payer == address(this)) {
            IERC20(tokenIn).transfer(msg.sender, uint256(amount));
        } else {
            IERC20(tokenIn).transferFrom(decoded.payer, msg.sender, uint256(amount));
        }
    }

    //单池交换
    function swapSingle(SwapSingleParams calldata params) public returns (uint256 amountOut) {
        amountOut = _swap(
            params.amountIn,
            msg.sender,
            params.sqrtPriceLimitX96,
            SwapCallbackData({
                path: abi.encodePacked(params.tokenIn, params.tickSpacing, params.tokenOut),
                payer: msg.sender
            })
        );
    }

    function _swap(uint256 amountIn, address recipient, uint160 sqrtPriceLimitX96, SwapCallbackData memory data)
        internal
        returns (uint256 amountOut)
    {
        //使用Path库提取池参数
        (address tokenIn, address tokenOut, uint24 tickSpacing) = data.path.decodeFirstPool();
        //实际交换
        (int256 amount0, int256 amount1) = getPool(tokenIn, tokenOut, tickSpacing).swap(
            recipient,
            tokenIn < tokenOut,
            amountIn,
            sqrtPriceLimitX96,
            abi.encode(IUniswapV3Pool.CallbackData({token0: tokenIn, token1: tokenOut, payer: msg.sender}))
        );

        //判断哪个为输出金额
        /**
         * 对于amount0和1
         * 正数：表示代币流入池子（用户付出）。
         * 负数：表示代币流出池子（用户接收）。
         * 所以amount0 和 amount1：本来是 int256 类型，表示代币的净变化量。
         * 如果 amount1 是负数，表示池子流出代币给用户。
         * 但返回值 amountOut 需要是 uint256（无符号整数）。
         * 取反负数：
         * amount1 可能是负值，比如 -300。
         * -(-300) = 300，转成 uint256，表示用户实际获得的代币数量。
         */
        amountOut = uint256(-(tokenIn < tokenOut ? amount1 : amount0));
    }

    //获取池
    function getPool(address token0, address token1, uint24 tickSpacing) internal view returns (IUniswapV3Pool pool) {
        (token0, token1) = token0 < token1 ? (token0, token1) : (token1, token0);
        pool = IUniswapV3Pool(PoolAddress.computeAddress(factory, token0, token1, tickSpacing));
    }
}
