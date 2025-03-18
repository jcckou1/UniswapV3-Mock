// SPDX-License-Identifier: UNLICENSED
pragma solidity ^0.8.14;

import "forge-std/Script.sol";
import "../test/ERC20Mintable.sol";
import "../src/UniswapV3Pool.sol";
import "../src/UniswapV3Manager.sol";

contract DeployDevelopment is Script {
    function run() external {
        uint256 wethBalance = 1 ether;
        //我们将铸造 5042 USDC——其中 5000 USDC 将作为流动性提供给资金池，42 USDC 将在交换中出售。
        uint256 usdcBalance = 5042 ether;
        int24 currentTick = 85176;
        uint160 currentSqrtP = 5602277097478614198912276234240;

        vm.startBroadcast();
        //部署代币
        ERC20Mintable token0 = new ERC20Mintable("Wrapped Ether", "WETH");
        ERC20Mintable token1 = new ERC20Mintable("USD Coin", "USDC");

        UniswapV3Pool pool = new UniswapV3Pool(address(token0), address(token1), currentSqrtP, currentTick);

        UniswapV3Manager manager = new UniswapV3Manager();

        //铸造代币
        token0.mint(address(this), wethBalance);
        token1.mint(address(this), usdcBalance);

        vm.stopBroadcast();

        console.log("WETH address", address(token0));
        console.log("USDC address", address(token1));
        console.log("Pool address", address(pool));
        console.log("Manager address", address(manager));
    }
}
