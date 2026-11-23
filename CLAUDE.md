# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this is

Imperial 70017 (Principles of Distributed Ledgers) coursework: a `HumanResources` Solidity contract implementing `src/IHumanResources.sol`, deployed to **Optimism mainnet**. The full spec is `70017_1_spec.pdf` — re-read it when a requirement is ambiguous. The majority of marks come from an **automated test suite run against the deployed contract**, so exact spec conformance (errors, events, decimals, access rules) matters more than anything else.

## Commands

```shell
forge build
forge test                                   # all tests (fork tests need RPC_URL + FORK_BLOCK from .env)
forge test --match-test test_Name -vvv       # single test
forge test --match-contract ForkSetupTest    # single test contract
forge fmt                                    # format
forge test --no-storage-caching              # cold-cache run, as the marker will see it
```

`.env` (gitignored; template in `.env.example`) provides `RPC_URL` and `FORK_BLOCK`. Tests must read these via `vm.envString("RPC_URL")` / `vm.envUint("FORK_BLOCK")` and fork with `vm.createSelectFork` — never hard-code the RPC URL. Use an Alchemy/Infura URL locally (public endpoint is slow/rate-limited), but the submitted `.env` must contain `RPC_URL=https://mainnet.optimism.io`.

Build config (`foundry.toml`): solc 0.8.24, `evm_version = cancun`, optimizer 200 runs; OpenZeppelin v5.1 via `@openzeppelin/contracts/` remapping (`lib/` are git submodules). `script/` is empty and `README.md` is still Foundry boilerplate; both are written in Stages 6–7.

## Architecture

- `src/HumanResources.sol` — the single deployed contract; inherits `IHumanResources` and OZ `ReentrancyGuard`, uses `SafeERC20`. `src/interfaces/` holds minimal Chainlink/Uniswap/WETH interfaces (don't pull in full Uniswap libs).
- **Accounting model:** per employee, `carriedUsd` (unpaid balance from earlier employment periods) + `earned` (computed fresh from `employedSince` to now/`terminatedAt` in a single division) − `paidUsd` (paid in the current period). Re-registration folds the pending balance into `carriedUsd` and zeroes `paidUsd`. Withdrawals add to `paidUsd` rather than checkpointing, so frequent withdrawals lose no precision; sub-USDC dust stays unpaid for later.
- **ETH path:** `_withdrawEth` rounds pending USD to whole USDC units, adds them to `paidUsd`, then swaps on the Uniswap V3 USDC/WETH **0.3%** pool (chosen over 0.05%, which exceeds 2% slippage at ≥10k USDC), unwraps WETH and pays with `Address.sendValue`. `receive()` only accepts ETH from WETH. `InvalidOraclePrice` is the one non-interface error.
- Tests: fork suites inherit `test/utils/HumanResourcesBase.sol`, which forks Optimism in `setUp()`, deploys a fresh `HumanResources`, funds it with `deal(USDC, ...)` and provides `_register` / `_terminate` / `_switchCurrency` / `_withdraw` / `_mockEthPrice` helpers. Suites: `HumanResources.t.sol` (core + USDC), `HumanResourcesEth.t.sol` (oracle/swap/reentrancy), `HumanResourcesFuzz.t.sol`, `ForkSetup.t.sol` (address smoke test).
  - Test accounts use `makeAddr("hr-test-*")`; generic labels like `"bob"` map to real Optimism accounts (an EIP-7702 sweeper), and the base asserts accounts are fresh.
  - Tests are marked using the rate-limited public RPC: never fuzz random addresses on a fork (`HumanResourcesAccessFuzzTest` runs off-fork for that reason). Check with `forge test --no-storage-caching`.

## Hard constraints

- Do **not** change the `IHumanResources` interface (signatures, errors, events). Do not add custom events.
- `src/HumanResources.sol` must not import `forge-std` or other test code (it would be deployed).
- Never verify the deployed contract. Deploy and call `submit` from the same wallet that claimed faucet ETH.
- The submitted source must exactly match the deployed bytecode — redeploy and resubmit after any change to `src/`.

## External contracts (Optimism)

| | Address | Notes |
|---|---|---|
| USDC (native, not USDC.e) | `0x0b2C639c533813f4Aa9D7837CAf62653d097Ff85` | 6 decimals |
| WETH | `0x4200000000000000000000000000000000000006` | unwrap before paying; pay ETH, never WETH |
| Chainlink ETH/USD | `0x13e3Ee699D1909E989722E753853AE30b17e08c5` | 8 decimals; staleness checks not required |
| Uniswap V3 SwapRouter | `0xE592427A0AEce92De3Edee1F18E0157C05861564` | `exactInputSingle`; minimal interface in `src/interfaces/` |
| Uniswap V3 Factory | `0x1F98431c8aD98523631AE4a59f267346ea31F984` | USDC/WETH pools exist at fees 100/500/3000; 3000 had most liquidity at FORK_BLOCK |
| Submission contract | `0x1e767Af5D01be07FA0Aa4367d8473957e58FAc4E` | `submit(address hrContract)` |

## Contract semantics (easy to get wrong)

- **Decimals:** inputs/`weeklyUsdSalary` are USD with 18 decimals; internal accounting stays in USD (18 dp). `salaryAvailable` and the `SalaryWithdrawn` amount use the *currency's* decimals: USDC → 6 (divide by 1e12), ETH → 18 (converted via oracle price, 8 dp).
- **Access:** register/terminate → `hrManager` only (`NotAuthorized` otherwise; `hrManager` immutable, set in constructor). `switchCurrency` → active employees only. `withdrawSalary` → active *or terminated* employees; never-registered → `NotAuthorized`. Views → anyone.
- **Accrual:** linear per second, `weeklyUsdSalary * elapsed / 1 weeks`; stops at termination; accrued balance survives termination and re-registration.
- **Re-registration** of a terminated employee: new `employedSince`, `terminatedAt = 0`, preference reset to USDC, accrual restarts from now, prior unwithdrawn balance kept. Registering an active employee → `EmployeeAlreadyRegistered`; terminating a non-active one → `EmployeeNotRegistered`.
- **ETH withdrawal:** zero the balance before external calls (CEI) + reentrancy guard; swap USDC→WETH with `amountOutMinimum` = 98% of oracle-expected ETH (must revert if worse); unwrap WETH (contract needs `receive()`); send ETH via `call`.
- `getEmployeeInfo` for unknown address returns all zeros without reverting; `salaryAvailable` returns 0.

## Submission package

Single zip with Foundry project at its root (not nested), excluding `.git`, `out/`, `cache/`, and this file. Must include `lib/`, `.env` (public RPC URL), `README.md` (per-function docs + AMM/oracle integration summary), `deployed-address.txt` (address only), `submit-transaction.txt` (tx hash only). `forge build` and `forge test` must pass after unzipping.

## Repo workflow

Commit directly on `main` and push to `origin main`; no feature branches.

`PROGRESS.md` tracks the user's goals and per-stage checklist — tick items and update stage status / "Last updated" whenever work completes. Exclude it from the submission zip.
