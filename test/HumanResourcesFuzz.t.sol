// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Test} from "forge-std/Test.sol";
import {HumanResources} from "../src/HumanResources.sol";
import {IHumanResources} from "../src/IHumanResources.sol";
import {HumanResourcesBase} from "./utils/HumanResourcesBase.sol";

/// @notice Property-based tests for accrual, termination, re-registration and ETH conversion
contract HumanResourcesFuzzTest is HumanResourcesBase {
    uint256 constant MAX_WEEKLY = 1_000_000e18;
    uint256 constant MAX_PERIOD = 520 weeks;

    function testFuzz_SalaryAvailable_MatchesFormula(uint256 weekly, uint256 elapsed) public {
        weekly = bound(weekly, 0, MAX_WEEKLY);
        elapsed = bound(elapsed, 0, MAX_PERIOD);
        _register(alice, weekly);
        skip(elapsed);
        assertEq(hr.salaryAvailable(alice), (weekly * elapsed) / 1 weeks / 1e12);
    }

    /// @dev Splitting a period into two withdrawals pays exactly the same as one withdrawal
    function testFuzz_SplitWithdrawals_PayExactTotal(uint256 weekly, uint256 first, uint256 second) public {
        weekly = bound(weekly, 0, 10_000e18);
        first = bound(first, 0, 52 weeks);
        second = bound(second, 0, 52 weeks);
        deal(address(USDC), address(hr), 2_000_000e6); // covers up to 104 weeks at the max rate
        _register(alice, weekly);

        skip(first);
        _withdraw(alice);
        skip(second);
        _withdraw(alice);

        uint256 expectedUsdc = (weekly * (first + second)) / 1 weeks / 1e12;
        assertEq(USDC.balanceOf(alice) + hr.salaryAvailable(alice), expectedUsdc);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function testFuzz_Termination_FreezesBalance(uint256 weekly, uint256 worked, uint256 afterwards) public {
        weekly = bound(weekly, 0, MAX_WEEKLY);
        worked = bound(worked, 0, MAX_PERIOD);
        afterwards = bound(afterwards, 0, MAX_PERIOD);
        _register(alice, weekly);
        skip(worked);
        _terminate(alice);
        uint256 frozen = hr.salaryAvailable(alice);
        skip(afterwards);
        assertEq(hr.salaryAvailable(alice), frozen);
        assertEq(frozen, (weekly * worked) / 1 weeks / 1e12);
    }

    function testFuzz_Reregistration_CarriesBalance(uint256 firstPeriod, uint256 gap, uint256 secondPeriod) public {
        firstPeriod = bound(firstPeriod, 0, 52 weeks);
        gap = bound(gap, 0, 52 weeks);
        secondPeriod = bound(secondPeriod, 0, 52 weeks);

        _register(alice, WEEKLY);
        skip(firstPeriod);
        _terminate(alice);
        skip(gap);
        _register(alice, 2 * WEEKLY);
        skip(secondPeriod);

        uint256 expectedUsd = (WEEKLY * firstPeriod) / 1 weeks + (2 * WEEKLY * secondPeriod) / 1 weeks;
        assertEq(hr.salaryAvailable(alice), expectedUsd / 1e12);
    }

    function testFuzz_SalaryAvailable_EthMatchesOracle(uint256 price, uint256 elapsed) public {
        price = bound(price, 100e8, 100_000e8); // 100 to 100k USD per ETH
        elapsed = bound(elapsed, 0, MAX_PERIOD);
        _register(alice, WEEKLY);
        _switchCurrency(alice);
        skip(elapsed);
        _mockEthPrice(int256(price));

        uint256 usd = (WEEKLY * elapsed) / 1 weeks;
        assertEq(hr.salaryAvailable(alice), (usd * 1e8) / price);
    }
}

/// @notice Access-control fuzzing. Runs without a fork: these paths revert before touching any
/// external contract, and random addresses would otherwise each cost RPC lookups.
contract HumanResourcesAccessFuzzTest is Test {
    HumanResources hr;
    address manager = makeAddr("hr-test-manager");
    address alice = makeAddr("hr-test-alice");
    uint256 constant WEEKLY = 700e18;

    function setUp() public {
        hr = new HumanResources(manager);
    }

    function testFuzz_RestrictedFunctions_RevertForNonManager(address caller) public {
        vm.assume(caller != manager);
        vm.startPrank(caller);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(alice, WEEKLY);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.terminateEmployee(alice);
        vm.stopPrank();
    }

    function testFuzz_EmployeeFunctions_RevertForNonEmployee(address caller) public {
        vm.startPrank(caller);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
        vm.stopPrank();
    }

    function testFuzz_TerminatedEmployee_CannotSwitchCurrency(address employee) public {
        vm.startPrank(manager);
        hr.registerEmployee(employee, WEEKLY);
        hr.terminateEmployee(employee);
        vm.stopPrank();

        vm.prank(employee);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
    }
}
