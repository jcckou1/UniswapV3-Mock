//SPDX-License-Identifier: MIT
pragma solidity ^0.8.14;

import "./interfaces/IUniswapV3PoolDeployer.sol";
import "./UniswapV3Pool.sol";
/**
 * Factory：定义parameters状态变量（实现IUniswapV3PoolDeployer）并在部署池子之前设置它。
 * Factory：部署一个池子。
 * Pool：在构造函数中，调用其部署者的parameters()函数，并期望返回池子参数。
 * Factory：调用delete parameters;来清理parameters状态变量的槽位并减少gas消耗。
 * 这是一个临时状态变量，只在调用createPool()期间有值。
 */

contract UniswapV3Factory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddress();
    error SameToken();
    error InvalidTickSpacing();

    event PoolCreated(address indexed token0, address indexed token1, int24 indexed tickSpacing, address pool);

    mapping(address => mapping(address => mapping(int24 => address))) public pools;
    mapping(address => bool) public isPool;

    function parameters() external view returns (address factory, address token0, address token1, uint24 tickSpacing) {
        factory = address(this);
        token0 = _parameters.token0;
        token1 = _parameters.token1;
        tickSpacing = uint24(_parameters.tickSpacing);
    }

    PoolParameters private _parameters;

    function createPool(address tokenX, address tokenY, int24 tickSpacing) public returns (address pool) {
        if (tokenX == tokenY) {
            revert SameToken();
        }

        if (tokenX == address(0) || tokenY == address(0)) {
            revert ZeroAddress();
        }

        if (pools[tokenX][tokenY][tickSpacing] != address(0)) {
            revert PoolAlreadyExists();
        }

        // 设置参数
        _parameters = PoolParameters({
            factory: address(this),
            token0: tokenX,
            token1: tokenY,
            tickSpacing: tickSpacing
        });

        // 部署池子
        pool = address(new UniswapV3Pool());

        // 删除参数
        delete _parameters;

        pools[tokenX][tokenY][tickSpacing] = pool;
        pools[tokenY][tokenX][tickSpacing] = pool;
        isPool[pool] = true;

        emit PoolCreated(tokenX, tokenY, tickSpacing, pool);
    }
}
