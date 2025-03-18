//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./lib/Tick.sol";
import "./lib/Position.sol";
import "./lib/TickBitmap.sol";
import "./lib/TickMath.sol";
import "./lib/Math.sol";
import "./interfaces/IERC20.sol";
import "./interfaces/IUniswapV3SwapCallback.sol";
import "./interfaces/IUniswapV3MintCallback.sol";
import "./interfaces/IUniswapV3FlashCallback.sol";
import "./interfaces/IUniswapV3PoolDeployer.sol";

contract UniswapV3Pool {
    error InvalidTickRange();
    error ZeroLiquidity();
    error InsufficientInputAmount();
    error InvalidPriceLimit();

    event Mint(
        address sender,
        address indexed owner,
        int24 indexed lowerTick,
        int24 indexed upperTick,
        uint128 liquidity,
        uint256 token0Amount,
        uint256 token1Amount
    );

    event Swap(
        address indexed sender,
        address indexed recipient,
        int256 amount0,
        int256 amount1,
        uint160 sqrtPriceX96,
        uint128 liquidity,
        int24 tick
    );

    event Flash(address indexed recipient, uint256 amount0, uint256 amount1);

    //把库挂载到类型上，使这个类型的所有变量都能直接访问库

    using Tick for mapping(int24 => Tick.Info);
    using Position for mapping(bytes32 => Position.Info);
    using Position for Position.Info;
    using TickBitmap for mapping(int24 => uint256);

    //uniswapV3定义最大最小Tick
    int24 internal constant MIN_TICK = -887272;
    int24 internal constant MAX_TICK = -MIN_TICK;

    // 池子代币，不可变
    address public immutable token0;
    address public immutable token1;

    Slot0 public slot0;

    // 流动性数量L
    uint128 public liquidity;

    // Ticks 信息
    mapping(int24 => Tick.Info) public ticks;
    // 头寸信息
    mapping(bytes32 => Position.Info) public positions;
    //位图
    mapping(int16 => uint256) public tickBitmap;

    // 打包一起读取的变量,储存池子的核心状态
    struct Slot0 {
        // 当前 sqrt(P)
        uint160 sqrtPriceX96;
        // 当前 tick
        int24 tick;
    }

    //方便回调函数选择不同代币地址，选择不同池子，以及不同用户
    struct CallbackData {
        address token0;
        address token1;
        address payer;
    }

    //SwapState维护当前交换的状态
    struct SwapState {
        uint256 amountSpecifiedRemaining; //池子需要购买的剩余代币数量，当它为零时，交换完成。即表示用户在交换中还剩余多少代币要换
        uint256 amountCalculated; //合约计算的输出数量（累积已交换的数量）
        uint160 sqrtPriceX96; //交换完成后的价格
        int24 tick; //交换完成后的tick
    }

    //StepState维护当前交换步骤的状态，这个结构跟踪"填充订单"的一次迭代的状态
    struct StepState {
        uint160 sqrtPriceStartX96; //迭代开始时的价格
        int24 nextTick; //将为交换提供流动性的下一个已初始化tick
        uint160 sqrtPriceNextX96; //下一个tick的价格
        uint256 amountIn; //当前迭代的流动性可以提供的数量
        uint256 amountOut; //当前迭代的流动性可以提供的数量
    }

    constructor() {
        //接受factory合约中的参数
        (factory, token0, token1, tickSpacing) = IUniswapV3PoolDeployer(msg.sender).parameters();
    }

    //初始化池子的价格和对应的tick
    function initialize(uint160 sqrtPriceX96) public {
        if (slot0.sqrtPriceX96 != 0) revert AlreadyInitialized();
        //根据价格算出tick
        int24 tick = TickMath.getTickAtSqrtRatio(sqrtPriceX96);
        //写入状态
        slot0 = Slot0({sqrtPriceX96: sqrtPriceX96, tick: tick});
    }

    //函数作用，用户用amount值的流动性能分别提供多少的amount0和amount1
    //amount为L值，而不是代币数量
    function mint(address owner, int24 lowerTick, int24 upperTick, uint128 amount, bytes calldata data)
        external
        returns (uint256 amount0, uint256 amount1)
    {
        if (lowerTick >= upperTick || lowerTick < MIN_TICK || upperTick > MAX_TICK) revert InvalidTickRange();
        if (amount == 0) revert ZeroLiquidity();

        //位图索引
        bool flippedLower = ticks.update(lowerTick, amount);
        bool flippedUpper = ticks.update(upperTick, amount);
        //lower和upper代表左右区间，说明是哪一边的tick发生了翻转
        if (flippedLower) {
            tickBitmap.flipTick(lowerTick, 1);
        }

        if (flippedUpper) {
            tickBitmap.flipTick(upperTick, 1);
        }

        ticks.update(lowerTick, amount);
        ticks.update(upperTick, amount);

        Position.Info storage position = positions.get(owner, lowerTick, upperTick);
        position.update(amount);

        Slot0 memory slot0_ = slot0;

        /**
         * 如果当前价格（tick暂表价格）在区间范围之下，那提供的流动性代币只需要提供给amount0
         * 因为假设用户觉得1eth的价值为2500-3000usdc，当价格变为1eth=2000usdc时，
         * 用户觉得它便宜，所以用户会需要用usdc去购买eth，所以此时流动性提供者只需要提供eth，
         *
         */
        if (slot0_.tick < lowerTick) {
            amount0 = Math.calcAmount0Delta(
                TickMath.getSqrtRatioAtTick(lowerTick), TickMath.getSqrtRatioAtTick(upperTick), amount
            );
        } else if (slot0_.tick < upperTick) {
            //在范围中
            amount0 = Math.calcAmount0Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(upperTick), amount);

            amount1 = Math.calcAmount1Delta(slot0_.sqrtPriceX96, TickMath.getSqrtRatioAtTick(lowerTick), amount);

            liquidity = LiquidityMath.addLiquidity(liquidity, int128(amount)); // TODO: amount is negative when removing liquidity
        } else {
            //反之
            amount1 = Math.calcAmount1Delta(
                TickMath.getSqrtRatioAtTick(lowerTick), TickMath.getSqrtRatioAtTick(upperTick), amount
            );
        }

        uint256 balance0Before;
        uint256 balance1Before;
        if (amount0 > 0) balance0Before = balance0();
        if (amount1 > 0) balance1Before = balance1();
        /**
         * 调用 uniswapV3MintCallback 回调函数，让用户将代币转到池子中。
         * 这是 Uniswap V3 的安全机制：池子不直接扣用户的钱，而是通过回调让用户主动完成转账。
         */
        //msg.sender一般是Manager合约，调用该合约中的函数进行回调
        IUniswapV3MintCallback(msg.sender).uniswapV3MintCallback(amount0, amount1, data);
        //确保已正确转移资金
        if (amount0 > 0 && balance0Before + amount0 > balance0()) {
            revert InsufficientInputAmount();
        }
        if (amount1 > 0 && balance1Before + amount1 > balance1()) {
            revert InsufficientInputAmount();
        }

        emit Mint(msg.sender, owner, lowerTick, upperTick, amount, amount0, amount1);
    }

    function swap(
        address recipient,
        bool zeroForOne, //用户想要交换代币的方向，true为token0->token1，false为token1->token0
        uint256 amountSpecified, //出售代币数
        uint160,
        sqrtPriceLimitX96, //滑点保护数
        bytes calldata data
    ) public returns (int256 amount0, int256 amount1) {
        Slot0 memory slot0_ = slot0;
        //判断是否超过滑点保护
        if (
            zeroForOne
                ? sqrtPriceLimitX96 > slot0_.sqrtPriceX96 || sqrtPriceLimitX96 < TickMath.MIN_SQRT_RATIO
                : sqrtPriceLimitX96 < slot0_.sqrtPriceX96 || sqrtPriceLimitX96 > TickMath.MAX_SQRT_RATIO
        ) revert InvalidPriceLimit();

        //初始化
        SwapState memory state = SwapState({
            amountSpecifiedRemaining: amountSpecified,
            amountCalculated: 0,
            sqrtPriceX96: slot0_.sqrtPriceX96,
            tick: slot0_.tick
        });

        while (state.amountSpecifiedRemaining > 0 && state.sqrtPriceX96 != sqrtPriceLimitX96) {
            StepState memory step;

            step.sqrtPriceStartX96 = state.sqrtPriceX96;

            //获取下一个Tick，tickBitmpa调用，作第一个参数传入,获取下一个tick是否初始化
            (step.nextTick, step.initialized) = tickBitmap.nextInitializedTickWithInOneWord(state.tick, 1, zeroForOne);

            //
            step.sqrtPriceNextX96 = TickMath.getSqrtRatioAtTick(step.nextTick);

            //计算交换步骤
            (state.sqrtPriceX96, step.amountIn, step.amountOut) = SwapMath.computeSwapStep(
                state.sqrtPriceX96,
                (zeroForOne ? step.sqrtPriceNextX96 < sqrtPriceLimitX96 : step.sqrtPriceNextX96 > sqrtPriceLimitX96)
                    ? sqrtPriceLimitX96
                    : step.sqrtPriceNextX96,
                state.liquidity,
                state.amountSpecifiedRemaining
            );

            //更新state
            state.amountSpecifiedRemaining -= step.amountIn; //价格范围中可以从用户那里购买的代币数量
            state.amountCalculated += step.amountOut; //池子可以卖给用户的相关的另一种代币的数量

            //state.sqrtPriceX96是新的当前价格，即当前交换后将设置的价格；step.sqrtPriceNextX96是下一个初始化价格刻度的价格。
            //如果这两个相等，我们就到达了价格范围的边界
            if (state.sqrtPriceX96 == step.sqrtPriceNextX96) {
                //判断此tick是否初始化
                if (step.initialized) {
                    //在特定范围内的流动性变化量，tick穿过一个范围后需要更新流动性
                    //用来标记：进入这个范围时应该激活多少流动性，离开这个范围时应该停用多少流动性
                    int128 liquidityDelta = ticks.cross(step.nextTick);
                    //为正数是相当于激活流动性，为负数时相当于停用流动性，看是向上超越海斯
                    if (zeroForOne) liquidityDelta = -liquidityDelta;

                    state.liquidity = LiquidityMath.addLiquidity(state.liquidity, liquidityDelta);

                    if (state.liquidity == 0) revert NotEnoughLiquidity();
                }

                state.tick = zeroForOne ? step.nextTick - 1 : step.nextTick;
            } else if (state.sqrtPriceX96 != step.sqrtPriceStartX96) {
                //价格在范围内时
                state.tick = TickMath.getTickAtSqrtRatio(state.sqrtPriceX96); //更新tick
            }
        }

        //为节省gas仅在不同时才更新
        if (state.tick != slot0_.tick) {
            (slot0.sqrtPriceX96, slot0.tick) = (state.sqrtPriceX96, state.tick);
        }

        //根据交换方向和在交换循环中计算的数量来计算金额
        (amount0, amount1) = zeroForOne
            ? (int256(amountSpecified - state.amountSpecifiedRemaining), -int256(state.amountCalculated))
            : (-int256(state.amountCalculated), int256(amountSpecified - state.amountSpecifiedRemaining));

        //交换代币
        if (zeroForOne) {
            IERC20(token1).transfer(recipient, uint256(-amount1));

            uint256 balance0Before = balance0();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance0Before + uint256(amount0) > balance0()) {
                revert InsufficientInputAmount();
            }
        } else {
            IERC20(token0).transfer(recipient, uint256(-amount0));

            uint256 balance1Before = balance1();
            IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
            if (balance1Before + uint256(amount1) > balance1()) {
                revert InsufficientInputAmount();
            }
        }

        int24 nextTick = 85184;
        uint160 nextPrice = 5604469350942327889444743441197;

        amount0 = -0.008396714242162444 ether;
        amount1 = 42 ether;

        //更新tick和sqrtP
        (slot0.tick, slot0.sqrtPriceX96) = (nextTick, nextPrice);

        //将资金传给接受者
        IERC20(token0).transfer(recipient, uint256(-amount0));
        //让调用者转账，否则回调
        uint256 balance1Before = balance1();
        //msg.sender一般是Manager合约，调用该合约中的函数进行回调
        IUniswapV3SwapCallback(msg.sender).uniswapV3SwapCallback(amount0, amount1, data);
        //似乎有隐藏bug，这里的amount1可能是负数
        if (amount1 > 0 && balance1Before + uint256(amount1) < balance1()) {
            revert InsufficientInputAmount();
        } else if (amount1 < 0 && balance1Before - uint256(-amount1) > balance1()) {
            revert InsufficientInputAmount();
        }
        emit Swap(msg.sender, recipient, amount0, amount1, slot0.sqrtPriceX96, liquidity, slot0.tick);
    }

    //闪电贷
    function flash(uint256 amount0, uint256 amount1, bytes calldata data) public {
        uint256 balance0Before = IERC20(token0).balanceOf(address(this));
        uint256 balance1Before = IERC20(token1).balanceOf(address(this));

        if (amount0 > 0) IERC20(token0).transfer(msg.sender, amount0);
        if (amount1 > 0) IERC20(token1).transfer(msg.sender, amount1);

        IUniswapV3FlashCallback(msg.sender).uniswapV3FlashCallback(data);

        require(IERC20(token0).balanceOf(address(this)) >= balance0Before);
        require(IERC20(token1).balanceOf(address(this)) >= balance1Before);

        emit Flash(msg.sender, amount0, amount1);
    }

    function balance0() internal view returns (uint256 balance) {
        balance = IERC20(token0).balanceOf(address(this));
    }

    function balance1() internal view returns (uint256 balance) {
        balance = IERC20(token1).balanceOf(address(this));
    }
}
