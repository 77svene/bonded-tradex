# 🛡️ BondedTradeX: Liability-Backed Autonomous Trading

> **The first DeFi trading agent to enforce economic liability via Dynamic Risk Bonding, ensuring trustless execution through collateralized risk buffers.**

## 🏆 Hackathon Context
**Event:** AI Trading Agents ERC-8004 | Lablab.ai  
**Prize Pool:** $55,000 SURGE token  
**Track:** Autonomous Agents & DeFi Security  

## 🚀 Problem & Solution

### The Problem
Autonomous trading agents in DeFi operate in a trustless environment, yet they lack **economic accountability**. Current ERC-8004 implementations focus on execution speed and strategy, but if an agent malfunctions, acts maliciously, or suffers from unexpected volatility, users bear the full loss. There is no mechanism to force the agent to pay for its mistakes.

### The Solution
**BondedTradeX** introduces a **Liability Layer** to the autonomous trading standard.
*   **Dynamic Risk Bonding:** The agent must stake SURGE tokens proportional to its strategy's risk score before executing swaps.
*   **Volatility Scaling:** The `RiskCalculator` service adjusts bond requirements in real-time using Chainlink Oracles.
*   **Automatic Liquidation:** If a trade results in a loss exceeding the agent's allocated risk buffer, the `BondingVault` automatically liquidates the agent's collateral to compensate the user.
*   **Trustless Execution:** The `AgentController` halts trading immediately if the bond-to-risk ratio drops below 1.0, preventing under-collateralized risk.

## 🏗️ Architecture

```text
+----------------+       +---------------------+       +------------------+
|    USER        |       |   AGENT SERVICE     |       |   BLOCKCHAIN     |
| (Trader)       |       |   (Node.js)         |       |   (Solidity)     |
+-------+--------+       +----------+----------+       +--------+---------+
        |                           |                           |
        | 1. Request Trade          |                           |
        |-------------------------->|                           |
        |                           | 2. Check Bond Sufficiency |
        |                           |<--------------------------|
        |                           |    (BondingVault.sol)     |
        |                           |                           |
        |                           | 3. Fetch Volatility       |
        |                           |<--------------------------|
        |                           |    (Chainlink Oracle)     |
        |                           |                           |
        |                           | 4. Sign & Execute         |
        |                           |-------------------------->|
        |                           |    (0x API Wrapper)       |
        |                           |                           |
        | 5. Receive Result         |                           |
        |<--------------------------|                           |
        |                           |                           |
        |                           | 6. Verify Loss/Bond       |
        |                           |<--------------------------|
        |                           |    (RiskCalculator.sol)   |
        |                           |                           |
        |                           | 7. Liquidate if Needed    |
        |                           |-------------------------->|
        |                           |    (BondingVault.sol)     |
        |                           |                           |
        +---------------------------+---------------------------+
```

## 🛠️ Tech Stack

| Technology | Usage |
| :--- | :--- |
| **Solidity** | Smart Contracts (`BondingVault`, `AgentController`) |
| **Node.js** | Agent Service & API Logic |
| **Hardhat** | Smart Contract Testing & Deployment |
| **Chainlink** | Volatility Oracles for Risk Calculation |
| **0x API** | Execution Layer for Token Swaps |
| **Circom** | ZK Proof Generation for Trade Verification |
| **OpenZeppelin** | Security Primitives (Modified) |

## 🚦 Setup Instructions

### 1. Clone Repository
```bash
git clone https://github.com/77svene/bonded-tradex
cd bonded-tradex
```

### 2. Install Dependencies
```bash
# Install Node dependencies
npm install

# Install Hardhat dependencies
npx hardhat install
```

### 3. Configure Environment
Create a `.env` file in the root directory:
```env
PRIVATE_KEY=your_wallet_private_key
RPC_URL=https://sepolia.infura.io/v3/your_api_key
SURGE_TOKEN_ADDRESS=0x...
CHAINLINK_FEED_ADDRESS=0x...
ZEROX_API_KEY=your_0x_api_key
```

### 4. Deploy Contracts
```bash
# Deploy to Sepolia Testnet
npx hardhat run scripts/deploy-sepolia.js --network sepolia
```

### 5. Start Agent Service
```bash
# Start the Node.js agent service
npm start
```

## 📡 API Endpoints

| Method | Endpoint | Description |
| :--- | :--- | :--- |
| `POST` | `/api/v1/bond` | Stake SURGE tokens to initialize agent liability |
| `GET` | `/api/v1/risk` | Fetch current volatility score and bond requirement |
| `POST` | `/api/v1/execute` | Submit trade request (validates bond before signing) |
| `GET` | `/api/v1/status` | Check bond-to-risk ratio and agent health |
| `POST` | `/api/v1/verify` | Submit ZK proof for trade verification |

## 🖥️ Demo

![Dashboard Demo](https://placehold.co/600x400/1a1a1a/FFF?text=BondedTradeX+Dashboard)

The dashboard provides real-time visibility into the agent's liability status.
*   **Live Bond Monitor:** Displays current collateral vs. required bond based on volatility.
*   **Trade History:** Logs all executed swaps with profit/loss metrics.
*   **Risk Alerts:** Notifications when the bond-to-risk ratio approaches the 1.0 threshold.
*   **Liquidation Log:** Tracks automatic collateral seizures triggered by excessive losses.

## 👥 Team

**Built by VARAKH BUILDER — autonomous AI agent**

*   **Core Architecture:** BondedTradeX Protocol
*   **Smart Contracts:** `contracts/AgentController.sol`, `contracts/BondingVault.sol`
*   **Agent Logic:** `services/agentService.js`, `services/zkProof.js`
*   **Verification:** `circuits/tradeProof.circom`

## 📄 License

This project is licensed under the MIT License - see the [LICENSE](LICENSE) file for details.

---
*Disclaimer: This software is for educational and hackathon purposes. DeFi trading involves significant risk. Always audit smart contracts before mainnet deployment.*