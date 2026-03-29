# 🏦 EVM Lending Core

![Solidity](https://img.shields.io/badge/Solidity-0.8.24-363636?style=flat-square&logo=solidity)
![DeFi](https://img.shields.io/badge/DeFi-Money_Market-blueviolet?style=flat-square)
![Coverage](https://img.shields.io/badge/Coverage-99%25-brightgreen?style=flat-square)

A decentralized, over-collateralized lending and borrowing infrastructure built for the Ethereum Virtual Machine (EVM).

This protocol implements the core mechanics of modern Money Markets (similar to Aave or Compound), focusing on strict risk management, precise cross-asset pricing via Oracles, and robust liquidation incentives to guarantee continuous protocol solvency.

## 🏗 Architecture & Risk Management

### 1. Health Factor & Solvency
- **Context:** If a user's collateral drops in value below their borrowed amount, the protocol accrues bad debt.
- **Implementation:** The system dynamically calculates a `Health Factor` for every position using real-time Oracle data. If the Health Factor drops below `1.0`, the position is flagged as undercollateralized and becomes immediately eligible for liquidation.

### 2. Cross-Asset Pricing (Oracle Integration)
- **Context:** Borrowing Token A against Token B requires a normalized valuation standard (usually USD).
- **Implementation:** The protocol integrates with decentralized price feeds (Oracles). The math engine safely normalizes token decimals (e.g., 18 decimals for WETH vs 6 decimals for USDC) against the Oracle's precision, ensuring mathematically sound Loan-to-Value (LTV) calculations.

### 3. Liquidation Engine & Incentives
- **Context:** The protocol relies on third-party keepers (liquidators) to clear bad debt.
- **Implementation:** When a position is liquidated, the liquidator repays the borrowed debt and receives the user's collateral plus a **Liquidation Bonus**. This financial incentive ensures that the free market constantly cleans up risky positions before the protocol goes underwater.

### 4. Reentrancy & State Security
- **Implementation:** Strict adherence to the CEI (Checks-Effects-Interactions) pattern across all state-mutating functions (`deposit`, `borrow`, `repay`, `liquidate`). External calls and asset transfers are executed only after internal accounting is fully updated.

## 🛠 Tech Stack

* **Core:** Solidity `0.8.24`
* **Integrations:** Chainlink-style Oracles (`IOracle`), WETH support.
* **Framework:** Foundry (Extensive unit testing and scenario simulation).

## 📊 Testing & Coverage

The protocol is rigorously tested against edge cases, including severe market downturns, oracle price drops, and forced liquidations.

To execute the test suite:
```bash
forge test
```

To view the coverage report:
```bash
forge coverage
```

**Coverage Output (Core Contracts):**

| File                    | % Lines          | % Statements     | % Branches     | % Funcs         |
|-------------------------|------------------|------------------|----------------|-----------------|
| src/LendingProtocol.sol | 99.45% (182/183) | 95.40% (228/239) | 70.27% (26/37) | 100.00% (29/29) |

*(Note: Mock contracts and interfaces are excluded from production coverage metrics).*