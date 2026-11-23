// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {Vm} from "forge-std/Test.sol";
import {Errors} from "@openzeppelin/contracts/utils/Errors.sol";
import {HumanResources} from "../src/HumanResources.sol";
import {IHumanResources} from "../src/IHumanResources.sol";
import {HumanResourcesBase} from "./utils/HumanResourcesBase.sol";

/// @notice ETH payouts: Chainlink conversion, Uniswap swap, slippage protection and reentrancy
contract HumanResourcesEthTest is HumanResourcesBase {
    function setUp() public override {
        super.setUp();
        _register(alice, WEEKLY);
        _switchCurrency(alice);
    }

    // ---------------- salaryAvailable (ETH) ----------------

    function test_SalaryAvailable_EthUsesOraclePrice() public {
        skip(1 weeks);
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
    }

    function test_SalaryAvailable_EthTracksOraclePriceChanges() public {
        skip(1 weeks);
        uint256 atMarket = hr.salaryAvailable(alice);
        _mockEthPrice(int256(_ethPrice() * 2));
        assertEq(hr.salaryAvailable(alice), atMarket / 2);
    }

    // ---------------- withdrawSalary (ETH) ----------------

    function test_Withdraw_Eth_WithinSlippageOfOracle() public {
        skip(1 weeks);
        uint256 expected = _usdToEth(700e18);

        vm.recordLogs();
        _withdraw(alice);

        uint256 received = alice.balance;
        assertGe(received, (expected * 98) / 100);
        assertLe(received, (expected * 102) / 100);
        assertEq(USDC.balanceOf(alice), 0);
        assertEq(WETH.balanceOf(alice), 0);
        assertEq(hr.salaryAvailable(alice), 0);
        assertEq(USDC.balanceOf(address(hr)), INITIAL_FUNDING - 700e6);
        // No ETH or WETH left behind in the contract
        assertEq(address(hr).balance, 0);
        assertEq(WETH.balanceOf(address(hr)), 0);

        // SalaryWithdrawn reports the ETH amount actually paid
        Vm.Log[] memory logs = vm.getRecordedLogs();
        Vm.Log memory last = logs[logs.length - 1];
        assertEq(last.emitter, address(hr));
        assertEq(last.topics[0], IHumanResources.SalaryWithdrawn.selector);
        assertEq(last.topics[1], bytes32(uint256(uint160(alice))));
        (bool isEth, uint256 amount) = abi.decode(last.data, (bool, uint256));
        assertTrue(isEth);
        assertEq(amount, received);
    }

    function test_Withdraw_Eth_LargeAmount() public {
        _register(bob, 50_000e18);
        _switchCurrency(bob);
        skip(1 weeks);
        uint256 expected = _usdToEth(50_000e18);
        _withdraw(bob);
        assertGe(bob.balance, (expected * 98) / 100);
    }

    function test_Withdraw_Eth_MixedCurrencyEmployees() public {
        _register(bob, WEEKLY); // stays in USDC
        skip(1 weeks);
        _withdraw(alice);
        _withdraw(bob);
        assertGt(alice.balance, 0);
        assertEq(USDC.balanceOf(alice), 0);
        assertEq(bob.balance, 0);
        assertEq(USDC.balanceOf(bob), 700e6);
    }

    function test_Withdraw_Eth_RevertsOnExcessiveSlippage() public {
        skip(1 weeks);

        // Oracle says ETH is 5% cheaper than the pool price -> pool returns ~5% less ETH than expected
        _mockEthPrice(int256((_ethPrice() * 95) / 100));
        vm.prank(alice);
        vm.expectRevert(bytes("Too little received"));
        hr.withdrawSalary();

        // Revert leaves the balance intact
        vm.clearMockedCalls();
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
        assertEq(USDC.balanceOf(address(hr)), INITIAL_FUNDING);
    }

    function test_Withdraw_Eth_SucceedsWithinTolerance() public {
        skip(1 weeks);

        // 1% oracle deviation is inside the 2% bound
        _mockEthPrice(int256((_ethPrice() * 99) / 100));
        _withdraw(alice);
        assertGt(alice.balance, 0);
    }

    function test_Withdraw_Eth_RevertsOnInvalidOraclePrice() public {
        skip(1 weeks);
        _mockEthPrice(0);
        vm.prank(alice);
        vm.expectRevert(HumanResources.InvalidOraclePrice.selector);
        hr.withdrawSalary();
    }

    function test_Withdraw_Eth_AfterTermination() public {
        skip(1 weeks);
        _terminate(alice);
        skip(1 weeks);
        assertEq(hr.salaryAvailable(alice), _usdToEth(700e18));
        _withdraw(alice);
        assertGt(alice.balance, 0);
        assertEq(hr.salaryAvailable(alice), 0);
    }

    function test_Withdraw_Eth_NothingAvailable_NoSwap() public {
        vm.recordLogs();
        _withdraw(alice);
        assertEq(vm.getRecordedLogs().length, 0);
        assertEq(alice.balance, 0);
        assertEq(USDC.balanceOf(address(hr)), INITIAL_FUNDING);
    }

    // ---------------- currency switching ----------------

    function test_SwitchCurrency_AccruedPaidInNewCurrency() public {
        _register(bob, WEEKLY);
        skip(1 weeks); // bob accrued while in USDC mode
        _switchCurrency(bob);
        _withdraw(bob);
        assertEq(USDC.balanceOf(bob), 0);
        assertGe(bob.balance, (_usdToEth(700e18) * 98) / 100);

        _switchCurrency(bob); // back to USDC
        skip(1 days);
        _withdraw(bob);
        assertEq(USDC.balanceOf(bob), 100e6);
    }

    function test_Reregister_EthBalancePaidInUsdc() public {
        skip(1 weeks);
        _terminate(alice);
        _register(alice, WEEKLY); // preference resets to USDC
        _withdraw(alice);
        assertEq(alice.balance, 0);
        assertEq(USDC.balanceOf(alice), 700e6);
    }

    // ---------------- security ----------------

    function test_Withdraw_Eth_ReentrancyBlocked() public {
        ReentrantEmployee attacker = new ReentrantEmployee(hr);
        _register(address(attacker), WEEKLY);
        _switchCurrency(address(attacker));
        skip(1 weeks);

        // Re-entering withdrawSalary from receive() trips the guard, so the ETH transfer
        // and the whole withdrawal revert
        vm.expectRevert(Errors.FailedCall.selector);
        attacker.attack();
        assertEq(address(attacker).balance, 0);
        assertEq(hr.salaryAvailable(address(attacker)), _usdToEth(700e18));
    }

    function test_Withdraw_Eth_RevertsIfRecipientRejectsEth() public {
        EthRejecter rejecter = new EthRejecter(hr);
        _register(address(rejecter), WEEKLY);
        _switchCurrency(address(rejecter));
        skip(1 weeks);

        vm.expectRevert(Errors.FailedCall.selector);
        rejecter.withdraw();
        assertEq(hr.salaryAvailable(address(rejecter)), _usdToEth(700e18));
    }

    function test_Receive_RejectsEthFromNonWeth() public {
        vm.deal(stranger, 1 ether);
        vm.prank(stranger);
        (bool ok,) = address(hr).call{value: 1 ether}("");
        assertFalse(ok);
        assertEq(address(hr).balance, 0);
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

/// @dev Employee contract with no way to receive ETH
contract EthRejecter {
    HumanResources immutable hr;

    constructor(HumanResources hr_) {
        hr = hr_;
    }

    function withdraw() external {
        hr.withdrawSalary();
    }
}
