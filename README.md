# HumanResources on Optimism

A Solidity HR payment system implementing the `IHumanResources` interface. The HR manager registers and terminates employees; employees accrue a weekly USD salary every second and withdraw it in USDC or ETH. ETH payouts are priced with the Chainlink ETH/USD oracle and swapped from USDC on Uniswap V3.

## Deployment

| | |
|---|---|
| Network | Optimism mainnet (chain ID 10) |
| `HumanResources` | `0xCac78A03Eefb0BC53f8c728e373A9Bba8d38476c` (see `deployed-address.txt`) |
| HR manager / submitter | `0x99B868bB39e51A8de93EA31b375Ab22D4Df34B16` |
| `submit` transaction | see `submit-transaction.txt` |

The contract was deployed with `script/Deploy.s.sol` and registered with `script/Submit.s.sol`; the broadcast logs are in `broadcast/`. The source in `src/HumanResources.sol` is exactly the deployed code.

## Build and test

Requires [Foundry](https://book.getfoundry.sh/). Dependencies (`forge-std`, OpenZeppelin Contracts v5.1.0) are vendored in `lib/`.

```shell
forge build
forge test
```

The tests fork Optimism. `.env` supplies the RPC endpoint and a pinned fork block, which Foundry loads automatically:

```
RPC_URL=https://mainnet.optimism.io
FORK_BLOCK=159793745
```

The public endpoint is rate-limited; replacing `RPC_URL` with an Alchemy or Infura URL makes the first run faster.

## Project layout

```
src/HumanResources.sol          the deployed contract
src/IHumanResources.sol         the provided interface (unchanged)
src/interfaces/                 minimal Chainlink, Uniswap V3 SwapRouter and WETH interfaces
script/                         deployment and submission scripts
test/utils/HumanResourcesBase.sol   shared fork setup and helpers
test/HumanResources.t.sol       access control, lifecycle, accrual, USDC withdrawals, views
test/HumanResourcesEth.t.sol    oracle conversion, swaps, slippage and reentrancy
test/HumanResourcesFuzz.t.sol   property-based tests
test/ForkSetup.t.sol            sanity checks on the external Optimism contracts
```

## Design

### Accounting

All salary accounting is in USD with 18 decimals. Each employee record stores:

| Field | Meaning |
|---|---|
| `weeklyUsdSalary` | weekly salary, USD 18 decimals |
| `employedSince` | timestamp of the latest registration (0 if never registered) |
| `terminatedAt` | timestamp of termination, 0 while active |
| `carriedUsd` | unpaid salary carried over from earlier employment periods |
| `paidUsd` | salary paid out during the current employment period |
| `isEth` | payout currency preference |

The amount owed is computed on demand:

```
earned  = weeklyUsdSalary * (end - employedSince) / 1 weeks     // end = terminatedAt, or now if active
pending = carriedUsd + earned - paidUsd
```

Earnings for the current period are always computed from `employedSince` in a single division, rather than checkpointed at each withdrawal, so withdrawing often never loses precision to repeated rounding. Payouts are rounded down to whole USDC units (6 decimals) and only that amount is added to `paidUsd`; any remainder below one USDC unit stays owed and is paid at a later withdrawal.

An employee is active when `employedSince != 0 && terminatedAt == 0`. An address has ever been registered when `employedSince != 0`.

### Access control

| Function | Who may call it | Otherwise |
|---|---|---|
| `registerEmployee`, `terminateEmployee` | `hrManager` only | `NotAuthorized` |
| `withdrawSalary` | active or terminated employees | `NotAuthorized` |
| `switchCurrency` | active employees only | `NotAuthorized` |
| views | anyone | |

`hrManager` is an `immutable` set in the constructor, so it can never be changed. The constructor rejects the zero address (`InvalidHrManager`).

## Interface functions

### `registerEmployee(address employee, uint256 weeklyUsdSalary)`

Reverts with `EmployeeAlreadyRegistered` if the employee is currently active. Otherwise it sets the salary, starts accrual from `block.timestamp` (`employedSince`), clears `terminatedAt` and resets the currency preference to USDC. For a terminated employee being re-registered, any salary not yet withdrawn is moved into `carriedUsd` and `paidUsd` is reset, so the old balance stays withdrawable while accrual restarts from the new registration time. Increments the active employee count and emits `EmployeeRegistered`.

### `terminateEmployee(address employee)`

Reverts with `EmployeeNotRegistered` unless the employee is currently active (never-registered and already-terminated employees are both rejected). Sets `terminatedAt = block.timestamp`, which freezes `earned`; the accrued balance is kept and can still be withdrawn. Decrements the active employee count and emits `EmployeeTerminated`.

### `withdrawSalary()`

Pays the caller's pending salary in their preferred currency. Protected by OpenZeppelin `ReentrancyGuard`, and the payout is recorded in `paidUsd` before any external call (checks-effects-interactions). If nothing is owed (less than one USDC unit), it returns without transferring or emitting.

- **USDC:** transfers `pending / 1e12` USDC with `SafeERC20` and emits `SalaryWithdrawn(employee, false, usdcAmount)`.
- **ETH:** swaps that USDC amount to WETH on Uniswap V3, unwraps it, sends ETH to the employee with OpenZeppelin `Address.sendValue`, and emits `SalaryWithdrawn(employee, true, ethAmount)` with the ETH actually paid (18 decimals). See below.

### `switchCurrency()`

Toggles the caller's preference between USDC and ETH and emits `CurrencySwitched(employee, isEth)`. It does not withdraw anything. Because accounting is in USD, no checkpoint is needed: salary accrued before the switch is paid in the new currency at the next withdrawal.

### `salaryAvailable(address employee)`

Returns the pending salary in the employee's preferred currency, scaled to that currency's decimals: USDC with 6 decimals, or ETH with 18 decimals converted at the current Chainlink price. Returns 0 for addresses that were never registered, and the frozen balance for terminated employees.

### `hrManager()`

Returns the HR manager address, set at deployment.

### `getActiveEmployeeCount()`

Returns a counter that is incremented on every registration and decremented on every termination, so it always equals the number of currently active employees.

### `getEmployeeInfo(address employee)`

Returns `(weeklyUsdSalary, employedSince, terminatedAt)`. `employedSince` is the latest (re-)registration time and `terminatedAt` is 0 while active. For an unknown address all three values are 0 and the call does not revert.

## Oracle and AMM integration

| Contract | Address |
|---|---|
| USDC (native) | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` |
| WETH | `0x4200000000000000000000000000000000000006` |
| Chainlink ETH/USD feed | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` |
| Uniswap V3 SwapRouter | `0xE592427A0AEce92De3Edee1F18E0157C05861564` |

**Oracle.** `_usdToEth` reads `latestRoundData()` from the Chainlink ETH/USD feed (8 decimals) and converts with `ethAmount = usdAmount * 10^8 / price`, giving ETH with 18 decimals. A non-positive price reverts with `InvalidOraclePrice`. As the coursework allows, there is no staleness check. The same conversion is used by `salaryAvailable` and to set the swap's minimum output.

**AMM.** An ETH withdrawal calls `exactInputSingle` on the Uniswap V3 SwapRouter, swapping exactly the employee's USDC amount for WETH, with the contract as recipient. The 0.3% fee pool is used: on the fork it returned within 0.7% of the oracle price for swaps from 1k to 50k USDC, whereas the 0.05% pool fell more than 2% short at 10k USDC and above. The received WETH is unwrapped with `WETH.withdraw`, and the contract's `receive()` only accepts ETH from the WETH contract.

**Slippage and manipulation protection.** `amountOutMinimum` is set to 98% of the ETH amount implied by the Chainlink price. If the pool returns more than 2% less than the oracle implies, because of slippage, front-running or a manipulated pool price, the router reverts with `Too little received` and the whole withdrawal is rolled back, leaving the employee's balance intact.

## Tests

61 tests, run on an Optimism fork pinned at `FORK_BLOCK`, cover 100% of lines, statements, branches and functions of `src/HumanResources.sol` (`forge coverage --report summary --no-match-coverage "test|lib"`).

- **Access control:** every restricted function rejects unauthorised callers with `NotAuthorized`, including the HR manager calling employee functions and terminated employees calling `switchCurrency`; fuzzed over arbitrary caller addresses.
- **Lifecycle:** registration, double registration, termination of never-registered and already-terminated employees, re-registration after partial and full withdrawals and over many cycles, active employee count.
- **Accrual:** linear accrual over partial and multiple weeks, rounding to USDC units, independent employees, accrual stopping at termination.
- **USDC withdrawals:** exact amounts and events, repeated withdrawals, withdrawal after termination, no event when nothing is owed, underfunded contract reverting with the balance kept.
- **ETH withdrawals:** payout within 2% of the oracle, `SalaryWithdrawn` reporting the ETH actually received, no ETH or WETH left in the contract, large swaps, mixed-currency employees, ETH value tracking oracle price changes.
- **Slippage:** a mocked oracle price 5% off reverts with `Too little received`; 1% off succeeds; a zero price reverts with `InvalidOraclePrice`.
- **Security:** a malicious employee contract re-entering `withdrawSalary` from `receive()` is blocked by the reentrancy guard; a recipient that cannot accept ETH makes the withdrawal revert without losing the balance; plain ETH transfers to the contract are rejected.
- **Fuzzing:** the accrual formula, split withdrawals paying exactly the same total as one withdrawal, termination freezing the balance, re-registration carrying the balance over, and ETH conversion across prices from 100 to 100,000 USD.

Test accounts use project-specific labels (`makeAddr("hr-test-alice")`), because common labels such as `makeAddr("bob")` resolve to real Optimism accounts. Access-control fuzzing runs without a fork so that random addresses do not trigger RPC requests.
