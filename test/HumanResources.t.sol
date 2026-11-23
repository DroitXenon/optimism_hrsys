// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {HumanResources} from "../src/HumanResources.sol";
import {IHumanResources} from "../src/IHumanResources.sol";
import {HumanResourcesBase} from "./utils/HumanResourcesBase.sol";

/// @notice Access control, registration lifecycle, accrual, USDC withdrawals and views
contract HumanResourcesTest is HumanResourcesBase {
    // ---------------- hrManager ----------------

    function test_HrManager() public view {
        assertEq(hr.hrManager(), manager);
    }

    function test_Constructor_RevertsOnZeroHrManager() public {
        vm.expectRevert(HumanResources.InvalidHrManager.selector);
        new HumanResources(address(0));
    }

    function test_HrManager_IsNotAnEmployee() public {
        vm.startPrank(manager);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.switchCurrency();
        vm.stopPrank();
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

    function test_Register_EmployeeCannotRegisterOthers() public {
        _register(alice, WEEKLY);
        vm.prank(alice);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.registerEmployee(bob, WEEKLY);
    }

    function test_Register_RevertsIfAlreadyActive() public {
        _register(alice, WEEKLY);
        vm.prank(manager);
        vm.expectRevert(IHumanResources.EmployeeAlreadyRegistered.selector);
        hr.registerEmployee(alice, 2 * WEEKLY);
    }

    function test_Reregister_ResetsTimestampsAndCurrency_KeepsBalance() public {
        _register(alice, WEEKLY);
        _switchCurrency(alice); // ETH
        skip(1 weeks);
        _terminate(alice);
        skip(3 days); // no accrual while terminated

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.EmployeeRegistered(alice, 1400e18);
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

    function test_Reregister_AfterPartialWithdrawal_PaysRemainderPlusNewAccrual() public {
        _register(alice, WEEKLY);
        skip(2 days);
        _withdraw(alice); // 200
        skip(1 days);
        _terminate(alice); // 100 left unpaid

        _register(alice, WEEKLY);
        skip(1 days);
        assertEq(hr.salaryAvailable(alice), 200e6);

        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 400e6);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Reregister_AfterFullWithdrawal_StartsFromZero() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _terminate(alice);
        _withdraw(alice);

        _register(alice, WEEKLY);
        assertEq(hr.salaryAvailable(alice), 0);
        skip(1 days);
        assertEq(hr.salaryAvailable(alice), 100e6);
    }

    function test_Reregister_ManyCycles_BalanceAccumulates() public {
        for (uint256 i = 0; i < 3; i++) {
            _register(alice, WEEKLY);
            skip(1 days);
            _terminate(alice);
            skip(1 weeks);
        }
        assertEq(hr.salaryAvailable(alice), 300e6);
        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 300e6);
    }

    // ---------------- terminateEmployee ----------------

    function test_Terminate_StopsAccrual() public {
        _register(alice, WEEKLY);
        skip(2 days);

        vm.expectEmit(true, false, false, false, address(hr));
        emit IHumanResources.EmployeeTerminated(alice);
        _terminate(alice);

        (uint256 weekly, uint256 since, uint256 terminatedAt) = hr.getEmployeeInfo(alice);
        assertEq(weekly, WEEKLY);
        assertEq(since, block.timestamp - 2 days);
        assertEq(terminatedAt, block.timestamp);
        assertEq(hr.getActiveEmployeeCount(), 0);

        skip(5 days);
        assertEq(hr.salaryAvailable(alice), 200e6);
    }

    function test_Terminate_DoesNotAffectOtherEmployees() public {
        _register(alice, WEEKLY);
        _register(bob, WEEKLY);
        skip(1 days);
        _terminate(alice);
        skip(1 days);
        assertEq(hr.salaryAvailable(alice), 100e6);
        assertEq(hr.salaryAvailable(bob), 200e6);
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

    function test_SalaryAvailable_RoundsDownToUsdcUnits() public {
        _register(alice, 1e18); // 1 USD per week
        skip(1); // 1/604800 USD = 1.65 USDC units
        assertEq(hr.salaryAvailable(alice), 1);
    }

    function test_SalaryAvailable_EmployeesAccrueIndependently() public {
        _register(alice, WEEKLY);
        skip(1 days);
        _register(bob, 1400e18);
        skip(1 days);
        assertEq(hr.salaryAvailable(alice), 200e6);
        assertEq(hr.salaryAvailable(bob), 200e6);
    }

    function test_SalaryAvailable_ZeroForUnknown() public view {
        assertEq(hr.salaryAvailable(stranger), 0);
    }

    // ---------------- withdrawSalary (USDC) ----------------

    function test_Withdraw_Usdc() public {
        _register(alice, WEEKLY);
        skip(1 weeks);

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.SalaryWithdrawn(alice, false, 700e6);
        _withdraw(alice);

        assertEq(USDC.balanceOf(alice), 700e6);
        assertEq(USDC.balanceOf(address(hr)), INITIAL_FUNDING - 700e6);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Withdraw_Twice_PaysOnlyNewAccrual() public {
        _register(alice, WEEKLY);
        skip(1 days);
        _withdraw(alice);
        skip(2 days);
        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 300e6);
    }

    function test_Withdraw_AfterTermination() public {
        _register(alice, WEEKLY);
        skip(3 days);
        _terminate(alice);
        skip(1 weeks);

        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 300e6);
    }

    function test_Withdraw_TerminatedWithZeroBalance_DoesNotRevert() public {
        _register(alice, WEEKLY);
        skip(1 days);
        _withdraw(alice);
        _terminate(alice);
        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 100e6);
    }

    function test_Withdraw_NothingAvailable_NoTransferNoEvent() public {
        _register(alice, WEEKLY);
        vm.recordLogs();
        _withdraw(alice);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(USDC.balanceOf(alice), 0);
    }

    function test_Withdraw_RevertsIfNeverRegistered() public {
        vm.prank(stranger);
        vm.expectRevert(IHumanResources.NotAuthorized.selector);
        hr.withdrawSalary();
    }

    function test_Withdraw_RevertsIfContractUnderfunded_BalanceKept() public {
        deal(address(USDC), address(hr), 100e6);
        _register(alice, WEEKLY);
        skip(1 weeks);

        vm.prank(alice);
        vm.expectRevert();
        hr.withdrawSalary();
        assertEq(hr.salaryAvailable(alice), 700e6);

        // Once HR tops up the contract the salary can be withdrawn
        deal(address(USDC), address(hr), INITIAL_FUNDING);
        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 700e6);
    }

    function test_Withdraw_DustKeptForLater() public {
        _register(alice, 0.5e18); // 0.5 USD/week: under 1 USDC unit (1e-6) per second
        skip(1);
        _withdraw(alice); // ~8.3e-7 USD accrued: nothing paid
        assertEq(USDC.balanceOf(alice), 0);
        skip(1 weeks - 1);
        _withdraw(alice);
        assertEq(USDC.balanceOf(alice), 0.5e6);
    }

    // ---------------- switchCurrency ----------------

    function test_SwitchCurrency_Toggles() public {
        _register(alice, WEEKLY);

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.CurrencySwitched(alice, true);
        _switchCurrency(alice);

        vm.expectEmit(true, false, false, true, address(hr));
        emit IHumanResources.CurrencySwitched(alice, false);
        _switchCurrency(alice);
    }

    function test_SwitchCurrency_DoesNotWithdraw() public {
        _register(alice, WEEKLY);
        skip(1 weeks);
        _switchCurrency(alice);
        assertEq(USDC.balanceOf(alice), 0);
        assertEq(alice.balance, 0);
        assertEq(USDC.balanceOf(address(hr)), INITIAL_FUNDING);

        _switchCurrency(alice);
        assertEq(hr.salaryAvailable(alice), 700e6);
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
        assertEq(hr.getActiveEmployeeCount(), 0);
        _register(alice, WEEKLY);
        _register(bob, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);
        _terminate(alice);
        assertEq(hr.getActiveEmployeeCount(), 1);
        _register(alice, WEEKLY);
        assertEq(hr.getActiveEmployeeCount(), 2);
    }

    function test_ActiveEmployeeCount_UnchangedByFailedCalls() public {
        _register(alice, WEEKLY);
        vm.startPrank(manager);
        vm.expectRevert(IHumanResources.EmployeeAlreadyRegistered.selector);
        hr.registerEmployee(alice, WEEKLY);
        vm.expectRevert(IHumanResources.EmployeeNotRegistered.selector);
        hr.terminateEmployee(bob);
        vm.stopPrank();
        assertEq(hr.getActiveEmployeeCount(), 1);
    }
}
