// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test, Vm} from "forge-std/Test.sol";
import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {HumanResources} from "../src/HumanResources.sol";
import {IHumanResources} from "../src/IHumanResources.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {AggregatorV3Interface} from "../src/interfaces/AggregatorV3Interface.sol";

contract HumanResourcesTest is Test {
    IERC20 constant USDC = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);
    IERC20 constant WETH = IERC20(0x4200000000000000000000000000000000000006);
    address constant ETH_USD_FEED = 0x13e3Ee699D1909E989722E753853AE30b17e08c5;

    HumanResources hr;
    address manager = makeAddr("manager");
    address alice = makeAddr("alice");
    address bob = makeAddr("bob");
    address stranger = makeAddr("stranger");

    uint256 constant WEEKLY = 700e18; // 100 USD per day

    function setUp() public {
        vm.createSelectFork(vm.envString("RPC_URL"), vm.envUint("FORK_BLOCK"));
        hr = new HumanResources(manager);
        deal(address(USDC), address(hr), 1_000_000e6);
    }

    function _register(address employee, uint256 weekly) internal {
        vm.prank(manager);
        hr.registerEmployee(employee, weekly);
    }

    function _terminate(address employee) internal {
        vm.prank(manager);
        hr.terminateEmployee(employee);
    }

    function _switchToEth(address employee) internal {
        vm.prank(employee);
        hr.switchCurrency();
    }

    function _ethPrice() internal view returns (uint256) {
        (, int256 price,,,) = AggregatorV3Interface(ETH_USD_FEED).latestRoundData();
        return uint256(price);
    }

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

    // ---------------- hrManager ----------------

    function test_HrManager() public view {
        assertEq(hr.hrManager(), manager);
    }

    // ---------------- registerEmployee ----------------

    function test_Register_SetsInfoAndCount() public {
        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.EmployeeRegistered(alice, WEEKLY);
        _register(alice, WEEKLY);

        (uint256 weekly, uint256 since, uint256 terminatedAt) = hr.getEmployeeInfo(alice);
        assertEq(weekly, WEEKLY);
        assertEq(since, block.timestamp);
        assertEq(terminatedAt, 0);
        assertEq(hr.getActiveEmployeeCount(), 1);
    }

    function test_Register_RevertsIfNotManager() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(alice, WEEKLY);
    }

    function test_Register_RevertsIfAlreadyActive() public {
        _register(alice, WEEKLY);
        vm.prank(manager);
        vm.expectRevert(IHumanResources.EmployeeAlreadyRegistered.selector);
        hr.registerEmployee(alice, WEEKLY);
    }

    function test_Reregister_ResetsTimestampsAndCurrency_KeepsBalance() public {
        _register(alice, WEEKLY);
        vm.prank(alice);
        hr.switchCurrency(); // ETH
        skip(1 weeks);
        _terminate(alice);
        skip(3 days); // no accrual while terminated

        _register(alice, 1400e18);
        (uint256 weekly, uint256 since, uint256 terminatedAt) = hr.getEmployeeInfo(alice);
        assertEq(weekly, 1400e18);
        assertEq(since, block.timestamp);
        assertEq(terminatedAt, 0);
        assertEq(hr.getActiveEmployeeCount(), 1);

        // Preference reset to USDC; old 700 USD balance kept, new rate accrues from now
        assertEq(hr.salaryAvailable(alice), 700e6);
        skip(1 days);
        assertEq(hr.salaryAvailable(alice), 900e6);
    }

    // ---------------- terminateEmployee ----------------

    function test_Terminate_StopsAccrual() public {
        _register(alice, WEEKLY);
        skip(2 days);

        vm.expectEmit(true, false, false, false, address(hr));
        emit IHumanResources.EmployeeTerminated(alice);
        _terminate(alice);

        (,, uint256 terminatedAt) = hr.getEmployeeInfo(alice);
        assertEq(terminatedAt, block.timestamp);
        assertEq(hr.getActiveEmployeeCount(), 0);

        skip(5 days);
        assertEq(hr.salaryAvailable(alice), 200e6);
    }

    function test_Terminate_RevertsIfNotManager() public {
        _register(alice, WEEKLY);
        vm.prank(alice);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.terminateEmployee(alice);
    }

    function test_Terminate_RevertsIfNeverRegistered() public {
        vm.prank(manager);
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        hr.terminateEmployee(alice);
    }

    function test_Terminate_RevertsIfAlreadyTerminated() public {
        _register(alice, WEEKLY);
        _terminate(alice);
        vm.prank(manager);
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        hr.terminateEmployee(alice);
    }

    // ---------------- accrual / salaryAvailable ----------------

    function test_SalaryAvailable_AccruesLinearly() public {
        _register(alice, WEEKLY);
        assertEq(hr.salaryAvailable(alice), 0);
        skip(12 hours);
        assertEq(hr.salaryAvailable(alice), 50e6);
        skip(2 weeks);
        assertEq(hr.salaryAvailable(alice), 1450e6);
    }

    function test_SalaryAvailable_ZeroForUnknown() public view {
        assertEq(hr.salaryAvailable(stranger), 0);
    }

    function testFuzz_SalaryAvailable_MatchesFormula(uint96 weekly, uint32 elapsed) public {
        _register(alice, weekly);
        skip(elapsed);
        uint256 expectedUsd = (uint256(weekly) * elapsed) / 1 weeks;
        assertEq(hr.salaryAvailable(alice), expectedUsd / 1e12);
    }

    // ---------------- withdrawSalary (USDC) ----------------

    function test_Withdraw_Usdc() public {
        _register(alice, WEEKLY);
        skip(1 weeks);

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.SalaryWithdrawn(alice, false, 700e6);
        vm.prank(alice);
        hr.withdrawSalary();

        assertEq(USDC.balanceOf(alice), 700e6);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Withdraw_Twice_PaysOnlyNewAccrual() public {
        _register(alice, WEEKLY);
        skip(1 days);
        vm.prank(alice);
        hr.withdrawSalary();
        skip(2 days);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 300e6);
    }

    function test_Withdraw_AfterTermination() public {
        _register(alice, WEEKLY);
        skip(3 days);
        _terminate(alice);
        skip(1 weeks);

        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 300e6);
    }

    function test_Withdraw_NothingAvailable_NoTransfer() public {
        _register(alice, WEEKLY);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 0);
    }

    function test_Withdraw_RevertsIfNeverRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    function test_Withdraw_DustKeptForLater() public {
        _register(alice, 0.5e18); // 0.5 USD/week: under 1 USDC unit (1e-6) per second
        skip(1);
        vm.prank(alice);
        hr.withdrawSalary(); // ~8.3e-7 USD accrued: nothing paid
        assertEq(USDC.balanceOf(alice), 0);
        skip(1 weeks - 1);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 0.5e6);
    }

    // ---------------- switchCurrency ----------------

    function test_SwitchCurrency_Toggles() public {
        _register(alice, WEEKLY);

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.CurrencySwitched(alice, true);
        vm.prank(alice);
        hr.switchCurrency();

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.CurrencySwitched(alice, false);
        vm.prank(alice);
        hr.switchCurrency();
    }

    function test_SwitchCurrency_RevertsIfNeverRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    function test_SwitchCurrency_RevertsIfTerminated() public {
        _register(alice, WEEKLY);
        _terminate(alice);
        vm.prank(alice);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }

    // ---------------- views ----------------

    function test_GetEmployeeInfo_ZeroForUnknown() public view {
        (uint256 weekly, uint256 since, uint256 terminatedAt) = hr.getEmployeeInfo(stranger);
        assertEq(weekly, 0);
        assertEq(since, 0);
        assertEq(terminatedAt, 0);
    }

    function test_ActiveEmployeeCount_TracksRegisterAndTerminate() public {
        _register(alice, WEEKLY);
        _register(bob, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);
        _terminate(alice);
        assertEq(hr.getActiveEmployeeCount(), 1);
        _register(alice, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);
    }

    // ---------------- ETH payouts (oracle + AMM) ----------------

    function test_SalaryAvailable_EthUsesOraclePrice() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
    }

    function test_Withdraw_Eth_WithinSlippageOfOracle() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);
        uint256 expected = _usdToEth(700e18);

        vm.recordLogs();
        vm.prank(alice);
        hr.withdrawSalary();

        uint256 received = alice.balance;
        assertGe(received, (expected * 98) / 100);
        assertLe(received, (expected * 102) / 100);
        assertEq(USDC.balanceOf(alice), 0);
        assertEq(hr.salaryAvailable(alice), 0);
        assertEq(USDC.balanceOf(address(hr)), 1_000_000e6 - 700e6);
        // No ETH or WETH left behind in the contract
        assertEq(address(hr).balance, 0);
        assertEq(WETH.balanceOf(address(hr)), 0);

        // SalaryWithdrawn reports the ETH amount actually paid
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.topics[0], IHumanResources.SalaryWithdrawn.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(alice))));
        (bool isEth, uint256 amount) = abi.decode(last.data, (bool, uint256));
        assertTrue(isEth);
        assertEq(amount, received);
    }

    function test_Withdraw_Eth_LargeAmount() public {
        _register(alice, 50_000e18);
        _switchToEth(alice);
        skip(1 weeks);
        uint256 expected = _usdToEth(50_000e18);
        vm.prank(alice);
        hr.withdrawSalary();
        assertGe(alice.balance, (expected * 98) / 100);
    }

    function test_Withdraw_Eth_RevertsOnExcessiveSlippage() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);

        // Oracle says ETH is 5% cheaper than the pool price -> pool returns ~5% less ETH than expected
        _mockEthPrice(int256((_ethPrice() * 95) / 100));
        vm.prank(alice);
        vm.expectRevert(bytes("Too little received"));
        hr.withdrawSalary();

        // Revert leaves the balance intact
        vm.clearMockedCalls();
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
    }

    function test_Withdraw_Eth_SucceedsWithinTolerance() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);

        // 1% oracle deviation is inside the 2% bound
        _mockEthPrice(int256((_ethPrice() * 99) / 100));
        vm.prank(alice);
        hr.withdrawSalary();
        assertGt(alice.balance, 0);
    }

    function test_Withdraw_Eth_RevertsOnInvalidOraclePrice() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);
        _mockEthPrice(0);
        vm.prank(alice);
        vm.expectRevert(HumanResources.InvalidOraclePrice.selector);
        hr.withdrawSalary();
    }

    function test_SwitchCurrency_AccruedPaidInNewCurrency() public {
        _register(alice, WEEKLY);
        skip(1 weeks); // accrued while in USDC mode
        _switchToEth(alice);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 0);
        assertGe(alice.balance, (_usdToEth(700e18) * 98) / 100);

        _switchToEth(alice); // back to USDC
        skip(1 days);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(USDC.balanceOf(alice), 100e6);
    }

    function test_Withdraw_Eth_AfterTermination() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
        vm.prank(alice);
        hr.withdrawSalary();
        assertGt(alice.balance, 0);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Withdraw_Eth_NothingAvailable_NoSwap() public {
        _register(alice, WEEKLY);
        _switchToEth(alice);
        vm.prank(alice);
        hr.withdrawSalary();
        assertEq(alice.balance, 0);
    }

    function test_Withdraw_Eth_ReentrancyBlocked() public {
        ReentrantEmployee attacker = new ReentrantEmployee(hr);
        _register(address(attacker), WEEKLY);
        vm.prank(address(attacker));
        hr.switchCurrency();
        skip(1 weeks);

        // Re-entering withdrawSalary from receive() trips the guard, so the ETH transfer
        // and the whole withdrawal revert
        vm.expectRevert(Errors.FailedCall.selector);
        attacker.attack();
        assertEq(address(attacker).balance, 0);
        assertEq(hr.salaryAvailable(address(attacker)), _usdToEth(700e18));
    }

    function test_Receive_RejectsEthFromNonWeth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(hr).call{value: 1 ether}("");
        assertFalse(ok);
    }
}

/// @dev Employee contract that tries to withdraw again while receiving ETH
contract ReentrantEmployee {
    HumanResources immutable hr;

    constructor(HumanResources hr_) {
        hr = hr_;
    }

    function attack() external {
        hr.withdrawSalary();
    }

    receive() external payable {
        hr.withdrawSalary();
    }
}
