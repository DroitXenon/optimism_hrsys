// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HumanResources} from "../../src/HumanResources.sol";
import {AggregatorV3Interface} from "../../src/interfaces/AggregatorV3Interface.sol";

/// @notice Shared fork setup and helpers for HumanResources tests
abstract contract HumanResourcesBase is Test {
    IERC20 constant USDC = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    IERC20 constant WETH = IERC20(0x4200000000000000000000000000000000000006);
    address constant ETH_USD_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;

    uint256 constant WEEKLY = 700e18; // 100 USD per day
    uint256 constant INITIAL_FUNDING = 1_000_000e6;

    HumanResources hr;
    // Project-specific labels: common ones like makeAddr("bob") resolve to real Optimism
    // accounts (e.g. EIP-7702 sweepers that forward away any ETH received)
    address manager = makeAddr("hr-test-manager");
    address alice = makeAddr("hr-test-alice");
    address bob = makeAddr("hr-test-bob");
    address stranger = makeAddr("hr-test-stranger");

    function setUp() public virtual {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
        _assertFreshAccounts();
        hr = new HumanResources(manager);
        deal(address(USDC), address(hr), INITIAL_FUNDING);
    }

    /// @dev Test accounts must be plain EOAs with no code or balances on the fork
    function _assertFreshAccounts() internal view {
        address[4] memory accounts = [manager, alice, bob, stranger];
        for (uint256 i = 0; i < accounts.length; i++) {
            assertEq(accounts[i].code.length, 0, "test account has code on fork");
            assertEq(accounts[i].balance, 0, "test account has ETH on fork");
            assertEq(USDC.balanceOf(accounts[i]), 0, "test account has USDC on fork");
        }
    }

    function _register(address employee, uint256 weekly) internal {
        vm.prank(manager);
        hr.registerEmployee(employee, weekly);
    }

    function _terminate(address employee) internal {
        vm.prank(manager);
        hr.terminateEmployee(employee);
    }

    function _switchCurrency(address employee) internal {
        vm.prank(employee);
        hr.switchCurrency();
    }

    function _withdraw(address employee) internal {
        vm.prank(employee);
        hr.withdrawSalary();
    }

    function _ethPrice() internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        return uint256(price);
    }

    /// @dev USD (18 dp) to ETH (18 dp) at the current feed price (8 dp)
    function _usdToEth(uint256 usd) internal view returns (uint256) {
        return (usd * 1e8) / _ethPrice();
    }

    function _mockEthPrice(int256 price) internal {
        vm.mockCall(
            ETH_USD_FEED,
            abi.encodeWithSelector(AggregatorV3Interface.latestRoundData.selector),
            abi.encode(uint80(1), price, block.timestamp, block.timestamp, uint80(1))
        );
    }
}
