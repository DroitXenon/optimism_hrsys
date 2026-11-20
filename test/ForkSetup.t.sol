// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20Metadata} from "@openzeppelin/contracts/token/ERC20/extensions/IERC20Metadata.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

/// @notice Sanity checks that the Optimism fork and external contracts are reachable
contract ForkSetupTest is Test {
    address constant USDC = 0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85;
    address constant WETH = 0x4200000000000000000000000000000000000006;
    address constant ETH_USD_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;
    address constant SWAP_ROUTER = 0xE592427A0AEce92De3Edee1F18E0157C05861564;

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
    }

    function test_ExternalContractsDeployed() public view {
        assertGt(USDC.code.length, 0);
        assertGt(WETH.code.length, 0);
        assertGt(ETH_USD_FEED.code.length, 0);
        assertGt(SWAP_ROUTER.code.length, 0);
    }

    function test_UsdcHasSixDecimals() public view {
        assertEq(IERC20Metadata(USDC).decimals(), 6);
    }

    function test_FeedReturnsPositivePrice() public view {
        AggregatorV3Interface feed = AggregatorV3Interface(ETH_USD_FEED);
        assertEq(feed.decimals(), 8);
        (, int256 answer,,,) = feed.latestRoundData();
        assertGt(answer, 0);
    }
}
