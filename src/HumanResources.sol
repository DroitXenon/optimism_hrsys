// SPDX-License-Identifier: GPL-3.0
pragma solidity ^0.8.24;

import {IERC20} from "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import {SafeERC20} from "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import {ReentrancyGuard} from "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import {IHumanResources} from "./IHumanResources.sol";

/// @title HumanResources
/// @notice HR payment system on Optimism: the HR manager registers and terminates employees,
/// who accrue a weekly USD salary per second and withdraw it in USDC or ETH.
/// @dev All salary accounting is in USD scaled to 18 decimals. Conversion to USDC (6 decimals)
/// or ETH (18 decimals) only happens when reading `salaryAvailable` or withdrawing.
contract HumanResources is IHumanResources, ReentrancyGuard {
    using SafeERC20 for IERC20;

    struct Employee {
        uint256 weeklyUsdSalary; // USD, 18 decimals
        uint256 employedSince; // timestamp of latest (re-)registration; 0 if never registered
        uint256 terminatedAt; // timestamp of termination; 0 while active
        uint256 carriedUsd; // unpaid salary carried over from previous employment periods
        uint256 paidUsd; // salary paid out during the current employment period
        bool isEth; // payout currency preference
    }

    IERC20 public constant USDC = IERC20(0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85);

    /// @dev USD amounts have 18 decimals, USDC has 6
    uint256 private constant USD_TO_USDC = 1e12;

    address public immutable hrManager;

    uint256 private _activeEmployeeCount;
    mapping(address => Employee) private _employees;

    modifier onlyHrManager() {
        if (msg.sender != hrManager) revert NotAuthorized();
        _;
    }

    constructor(address hrManager_) {
        hrManager = hrManager_;
    }

    // ------------------------------------------------------------------
    // HR manager functions
    // ------------------------------------------------------------------

    /// @inheritdoc IHumanResources
    function registerEmployee(address employee, uint256 weeklyUsdSalary) external onlyHrManager {
        Employee storage e = _employees[employee];
        if (_isActive(e)) revert EmployeeAlreadyRegistered();

        // A re-registered employee keeps any unwithdrawn balance from the previous period;
        // accrual restarts from now with the default USDC preference.
        e.carriedUsd = _pendingUsd(e);
        e.paidUsd = 0;
        e.weeklyUsdSalary = weeklyUsdSalary;
        e.employedSince = block.timestamp;
        e.terminatedAt = 0;
        e.isEth = false;
        _activeEmployeeCount++;

        emit EmployeeRegistered(employee, weeklyUsdSalary);
    }

    /// @inheritdoc IHumanResources
    function terminateEmployee(address employee) external onlyHrManager {
        Employee storage e = _employees[employee];
        if (!_isActive(e)) revert EmployeeNotRegistered();

        e.terminatedAt = block.timestamp;
        _activeEmployeeCount--;

        emit EmployeeTerminated(employee);
    }

    // ------------------------------------------------------------------
    // Employee functions
    // ------------------------------------------------------------------

    /// @inheritdoc IHumanResources
    function withdrawSalary() external nonReentrant {
        Employee storage e = _employees[msg.sender];
        // Active and terminated employees may withdraw; never-registered addresses may not
        if (e.employedSince == 0) revert NotAuthorized();

        if (e.isEth) {
            _withdrawEth(e);
        } else {
            _withdrawUsdc(e);
        }
    }

    /// @inheritdoc IHumanResources
    function switchCurrency() external {
        Employee storage e = _employees[msg.sender];
        if (!_isActive(e)) revert NotAuthorized();

        // Accounting is in USD, so switching needs no checkpoint
        e.isEth = !e.isEth;

        emit CurrencySwitched(msg.sender, e.isEth);
    }

    // ------------------------------------------------------------------
    // Views
    // ------------------------------------------------------------------

    /// @inheritdoc IHumanResources
    function salaryAvailable(address employee) external view returns (uint256) {
        Employee storage e = _employees[employee];
        uint256 usd = _pendingUsd(e);
        return e.isEth ? _usdToEth(usd) : usd / USD_TO_USDC;
    }

    /// @inheritdoc IHumanResources
    function getActiveEmployeeCount() external view returns (uint256) {
        return _activeEmployeeCount;
    }

    /// @inheritdoc IHumanResources
    function getEmployeeInfo(address employee)
        external
        view
        returns (uint256 weeklyUsdSalary, uint256 employedSince, uint256 terminatedAt)
    {
        Employee storage e = _employees[employee];
        return (e.weeklyUsdSalary, e.employedSince, e.terminatedAt);
    }

    // ------------------------------------------------------------------
    // Internal
    // ------------------------------------------------------------------

    function _isActive(Employee storage e) private view returns (bool) {
        return e.employedSince != 0 && e.terminatedAt == 0;
    }

    /// @dev Unpaid salary up to now, in USD 18 decimals. Earnings for the current period are
    /// always computed from `employedSince` in one division, so withdrawing often loses no precision.
    /// Accrual stops at `terminatedAt`.
    function _pendingUsd(Employee storage e) private view returns (uint256) {
        if (e.employedSince == 0) return 0;
        uint256 end = e.terminatedAt == 0 ? block.timestamp : e.terminatedAt;
        uint256 earned = (e.weeklyUsdSalary * (end - e.employedSince)) / 1 weeks;
        return e.carriedUsd + earned - e.paidUsd;
    }

    function _withdrawUsdc(Employee storage e) private {
        uint256 usdcAmount = _pendingUsd(e) / USD_TO_USDC;
        if (usdcAmount == 0) return;

        // Dust below USDC precision stays unpaid for a later withdrawal
        // forge-lint: disable-next-line(divide-before-multiply)
        e.paidUsd += usdcAmount * USD_TO_USDC;
        USDC.safeTransfer(msg.sender, usdcAmount);

        emit SalaryWithdrawn(msg.sender, false, usdcAmount);
    }

    /// @dev Implemented in Stage 3 (Chainlink price + Uniswap swap)
    function _withdrawEth(Employee storage) private pure {
        revert("ETH payout not implemented");
    }

    /// @dev Implemented in Stage 3 (Chainlink price)
    function _usdToEth(uint256) private pure returns (uint256) {
        revert("ETH payout not implemented");
    }
}
