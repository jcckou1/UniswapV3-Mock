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

contract UniswapV3Factrory is IUniswapV3PoolDeployer {
    error PoolAlreadyExists();
    error ZeroAddressNotAllowed();
    error TokensMustBeDifferent();
    error UnsupportedTickSpacing();

    PoolParameters public parameters;
    mapping(address tokenA => mapping(address tokenB => mapping(uint24 tickSpacing => address pool))) public pools;
    mapping(uint24 => bool) public tickSpacings;

    constructor() {
        tickSpacings[10] = true;
        tickSpacings[60] = true;
    }

    function createPool(address tokenX, address tokenY, uint24 tickSpacing) public returns (address pool) {
        if (tokenX == tokenY) revert TokensMustBeDifferent();
        if (!tickSpacings[tickSpacing]) revert UnsupportedTickSpacing();
        //对token排序，执行这一点是为了使salt（和池子地址）的计算保持一致,X<Y
        (tokenX, tokenY) = tokenX < tokenY ? (tokenX, tokenY) : (tokenY, tokenX);

        if (tokenX == address(0)) revert ZeroAddressNotAllowed();
        if (pools[tokenX][tokenY][tickSpacing] != address(0)) {
            revert PoolAlreadyExists();
        }
        //池子参数
        parameters = PoolParameters({factory: address(this), token0: tokenX, token1: tokenY, tickSpacing: tickSpacing});
        //创建新合约实例，其中已经用完了parameters中的值，在pool的constructor中
        pool = address(new UniswapV3Pool{salt: keccak256(abi.encodePacked(tokenX, tokenY, tickSpacing))}());
        //清除parameters结构体中的值
        delete parameters;
        //添加索引
        pools[tokenX][tokenY][tickSpacing] = pool;
        pools[tokenY][tokenX][tickSpacing] = pool;

        emit PoolCreated(tokenX, tokenY, tickSpacing, pool);
    }
}
