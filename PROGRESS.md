# Coursework Progress — 70017 HumanResources on Optimism

Last updated: 2026-11-23

## Goals

1. **Deployed contract passes the official test suite** (majority of marks: correctness, security, integration).
2. **Off-chain submission** is complete and builds/tests cleanly after unzipping (code quality + test quality marks).
3. **Thorough fork test suite** covering every interface function, success and failure cases.

## Stages

| # | Stage | Status |
|---|---|---|
| 1 | Project setup | ✅ Done |
| 2 | Core contract (no swaps) | ✅ Done |
| 3 | Oracle + AMM integration | ✅ Done |
| 4 | Fork test suite | ⬜ Not started |
| 5 | Review & hardening | ⬜ Not started |
| 6 | Deploy & on-chain submit | ⬜ Not started |
| 7 | Package off-chain submission | ⬜ Not started |

### 1. Project setup ✅
- [x] Foundry project, `forge-std` v1.17.0, OpenZeppelin v5.1.0
- [x] `src/IHumanResources.sol` (unchanged ABI)
- [x] Minimal interfaces: Chainlink `AggregatorV3Interface`, Uniswap `ISwapRouter`, `IWETH`
- [x] `.env` / `.env.example` with `RPC_URL` and `FORK_BLOCK=159793745`
- [x] Fork smoke test `test/ForkSetup.t.sol` (3/3 passing)
- [x] Checked USDC/WETH pools: 0.3% tier has most liquidity at fork block
- [x] `CLAUDE.md`

### 2. Core contract (no swaps) ✅
- [x] `HumanResources` with immutable `hrManager` set in constructor
- [x] Employee storage: salary, employedSince, terminatedAt, carriedUsd, paidUsd, isEth
- [x] Accrual from `employedSince` in one division (no per-withdrawal rounding loss)
- [x] `registerEmployee` (incl. re-registration rules, preference reset to USDC)
- [x] `terminateEmployee` (stop accrual, keep balance)
- [x] `switchCurrency` (active only)
- [x] `withdrawSalary` — USDC path (18 → 6 decimals)
- [x] Views: `salaryAvailable`, `hrManager`, `getActiveEmployeeCount`, `getEmployeeInfo`
- [x] Core tests `test/HumanResources.t.sol` (23 passing incl. fuzz); ETH paths stubbed until Stage 3

### 3. Oracle + AMM integration ✅
- [x] USD → ETH conversion via Chainlink (8 dp); reverts `InvalidOraclePrice` on price ≤ 0
- [x] USDC → WETH swap via `exactInputSingle`, `amountOutMinimum` = 98% of oracle quote
- [x] Pool fee tier: 0.3% (3000) — quoted within 0.7% of oracle for 1k–50k USDC; 0.05% fails 2% bound at ≥10k
- [x] Unwrap WETH, `receive()` (WETH only), send ETH via `Address.sendValue`; balance marked paid before calls + `nonReentrant`
- [x] `salaryAvailable` in ETH mode
- [x] ETH tests: oracle-based view, payout within bounds, large swap, slippage revert, 1% tolerance, invalid price, currency switch, post-termination, reentrancy attack, receive guard (37 tests total)

### 4. Fork test suite
- [ ] Access control reverts (`NotAuthorized`) for every restricted function
- [ ] Register / double-register / terminate / terminate non-active
- [ ] Accrual: partial weeks, multiple weeks, stop at termination
- [ ] Re-registration keeps old balance and resets currency
- [ ] USDC and ETH withdrawals; events via `vm.expectEmit`
- [ ] Slippage revert (mock oracle price)
- [ ] Reentrancy attempt via malicious receiver
- [ ] Unknown address views return zeros
- [ ] Fuzz tests on accrual

### 5. Review & hardening
- [ ] Re-check every spec requirement
- [ ] Decimal scaling audit at each boundary
- [ ] No test imports in `src/`; `forge fmt`

### 6. Deploy & on-chain submit
- [ ] Claim faucet ETH (wallet: _TBD_)
- [ ] Deploy `HumanResources` to Optimism — **do not verify**
- [ ] Call `submit(<HR address>)` from the same wallet
- [ ] Write `deployed-address.txt` and `submit-transaction.txt`

### 7. Package off-chain submission
- [ ] `README.md`: per-function docs + AMM/oracle integration summary
- [ ] `.env` set to `https://mainnet.optimism.io`
- [ ] Unzip into a clean dir and confirm `forge build` + `forge test`
- [ ] Zip from root, excluding `.git`, `out/`, `cache/`, `CLAUDE.md`, `PROGRESS.md`

## Notes / decisions
- Commit directly to `main`.
- `salaryAvailable` / `SalaryWithdrawn` amounts use currency decimals (USDC 6, ETH 18); internal accounting in USD 18 dp.
