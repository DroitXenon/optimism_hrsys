# Coursework Progress — 70017 HumanResources on Optimism

Last updated: 2026-11-23

## Goals

1. **Deployed contract passes the official test suite** (majority of marks: correctness, security, integration).
2. **Off-chain submission** is complete and builds/tests cleanly after unzipping (code quality + test quality marks).
3. **Thorough fork test suite** covering every interface function, success and failure cases.

## Stages

| # | Stage | Status |
|---|---|---|
| 1 | Project setup | Done |
| 2 | Core contract (no swaps) | Done |
| 3 | Oracle + AMM integration | Done |
| 4 | Fork test suite | Done |
| 5 | Review & hardening | Done |
| 6 | Deploy & on-chain submit | Done |
| 7 | Package off-chain submission | Not started |

### 1. Project setup (done)
- [x] Foundry project, `forge-std` v1.17.0, OpenZeppelin v5.1.0
- [x] `src/IHumanResources.sol` (unchanged ABI)
- [x] Minimal interfaces: Chainlink `AggregatorV3Interface`, Uniswap `ISwapRouter`, `IWETH`
- [x] `.env` / `.env.example` with `RPC_URL` and `FORK_BLOCK=159793745`
- [x] Fork smoke test `test/ForkSetup.t.sol` (3/3 passing)
- [x] Checked USDC/WETH pools: 0.3% tier has most liquidity at fork block
- [x] `CLAUDE.md`

### 2. Core contract (no swaps) (done)
- [x] `HumanResources` with immutable `hrManager` set in constructor
- [x] Employee storage: salary, employedSince, terminatedAt, carriedUsd, paidUsd, isEth
- [x] Accrual from `employedSince` in one division (no per-withdrawal rounding loss)
- [x] `registerEmployee` (incl. re-registration rules, preference reset to USDC)
- [x] `terminateEmployee` (stop accrual, keep balance)
- [x] `switchCurrency` (active only)
- [x] `withdrawSalary` — USDC path (18 → 6 decimals)
- [x] Views: `salaryAvailable`, `hrManager`, `getActiveEmployeeCount`, `getEmployeeInfo`
- [x] Core tests `test/HumanResources.t.sol` (23 passing incl. fuzz); ETH paths stubbed until Stage 3

### 3. Oracle + AMM integration (done)
- [x] USD → ETH conversion via Chainlink (8 dp); reverts `InvalidOraclePrice` on price ≤ 0
- [x] USDC → WETH swap via `exactInputSingle`, `amountOutMinimum` = 98% of oracle quote
- [x] Pool fee tier: 0.3% (3000) — quoted within 0.7% of oracle for 1k–50k USDC; 0.05% fails 2% bound at ≥10k
- [x] Unwrap WETH, `receive()` (WETH only), send ETH via `Address.sendValue`; balance marked paid before calls + `nonReentrant`
- [x] `salaryAvailable` in ETH mode
- [x] ETH tests: oracle-based view, payout within bounds, large swap, slippage revert, 1% tolerance, invalid price, currency switch, post-termination, reentrancy attack, receive guard (37 tests total)

### 4. Fork test suite (done)
- [x] Split into `test/utils/HumanResourcesBase.sol` (fork setup, helpers) + core, ETH and fuzz suites
- [x] Access control reverts (`NotAuthorized`) for every restricted function, incl. manager calling employee functions
- [x] Register / double-register / terminate / terminate non-active; failed calls leave count unchanged
- [x] Accrual: partial weeks, multiple weeks, rounding to USDC units, independent employees, stop at termination
- [x] Re-registration: keeps balance, resets currency, correct after partial/full withdrawal and many cycles
- [x] USDC and ETH withdrawals; events checked (incl. no event when nothing is owed)
- [x] Underfunded contract reverts and keeps balance
- [x] Slippage revert, 1% tolerance, invalid oracle price, ETH view tracks oracle price
- [x] Reentrancy attack and ETH-rejecting recipient
- [x] Fuzz: formula, split withdrawals pay exact total, termination freezes balance, re-registration carry-over, ETH conversion, access control (off-fork)
- [x] 60 tests passing on the public RPC with no fork cache (`forge test --no-storage-caching`)

### 5. Review & hardening (done)
- [x] Line-by-line check of every spec requirement (sections 1-6 and the access-control note) against the contract: no gaps found
- [x] Decimal scaling checked at each boundary (USD 18 dp, USDC 6 dp, Chainlink 8 dp, ETH 18 dp)
- [x] `src/` imports only OpenZeppelin and local interfaces; `forge fmt --check` clean
- [x] Constructor rejects a zero `hrManager` (`InvalidHrManager`) with test
- [x] All linter warnings resolved: zero-check fixed; reentrancy/unused-return false positives suppressed with reasons
- [x] Coverage of `src/HumanResources.sol`: 100% lines, statements, branches, functions
- [x] 61 tests passing, incl. cold-cache run on public RPC

### 6. Deploy & on-chain submit (done)
- [x] `script/Deploy.s.sol` (hrManager = deployer unless `HR_MANAGER` set) and `script/Submit.s.sol` (refuses addresses without HumanResources code)
- [x] Full deploy + submit rehearsal on a local Anvil fork of Optimism
- [x] Faucet ETH claimed; key in Foundry keystore as `hr-deployer` (wallet `0x99B868bB39e51A8de93EA31b375Ab22D4Df34B16`)
- [x] Deployed `HumanResources` at `0xCac78A03Eefb0BC53f8c728e373A9Bba8d38476c` (block 159915492, tx `0xfcb08e24...f7f5`), not verified; on-chain bytecode matches local build
- [x] `submit` tx `0x3a8e8a07380d516d855810de45c1e030d8267819167cfc306cc661b6a5ab2f09` (block 159915548) from the same wallet, success
- [x] `deployed-address.txt` and `submit-transaction.txt` written
- [x] Live smoke test on a fork of the deployed contract: USDC and ETH withdrawals work (ETH 0.31% under oracle)

**Any change to `src/` from here on requires redeploying and resubmitting.**

### 7. Package off-chain submission
- [ ] `README.md`: per-function docs + AMM/oracle integration summary
- [ ] `.env` set to `https://mainnet.optimism.io`
- [ ] Unzip into a clean dir and confirm `forge build` + `forge test`
- [ ] Zip from root, excluding `.git`, `out/`, `cache/`, `CLAUDE.md`, `PROGRESS.md`

## Notes / decisions
- Test accounts use `makeAddr("hr-test-*")` labels: `makeAddr("bob")` is an EIP-7702 sweeper on Optimism.
- Access-control fuzz runs off-fork so random addresses do not hit the public RPC rate limit.
- Commit directly to `main`.
- `salaryAvailable` / `SalaryWithdrawn` amounts use currency decimals (USDC 6, ETH 18); internal accounting in USD 18 dp.
