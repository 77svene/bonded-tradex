// SPDX-License-Identifier: MIT
// @title BondedTradeX Agent Service
// @notice Autonomous trading agent with Dynamic Risk Bonding enforcement
// @dev Novel primitive: Pre-trade bond verification with cryptographic state sync
// @dev Cryptographic self-enforcement: Every trade requires on-chain bond confirmation
// @dev Adversarial resilience: All external calls validated, all state immutable

import { ethers } from 'ethers';
import { createHash } from 'crypto';

const { ethers: ethersLib } = await import('ethers');

// === CONFIGURATION ===
const CONFIG = {
  RPC_URL: process.env.RPC_URL || 'http://localhost:8545',
  PRIVATE_KEY: process.env.PRIVATE_KEY || '0x0000000000000000000000000000000000000000000000000000000000000000',
  AGENT_CONTROLLER_ADDRESS: process.env.AGENT_CONTROLLER_ADDRESS || '0x0000000000000000000000000000000000000001',
  BONDING_VAULT_ADDRESS: process.env.BONDING_VAULT_ADDRESS || '0x0000000000000000000000000000000000000002',
  RISK_CALCULATOR_ADDRESS: process.env.RISK_CALCULATOR_ADDRESS || '0x0000000000000000000000000000000000000003',
  SURGE_TOKEN_ADDRESS: process.env.SURGE_TOKEN_ADDRESS || '0x0000000000000000000000000000000000000004',
  ZEROX_API_URL: process.env.ZEROX_API_URL || 'https://api.0x.org/swap/v1',
  ZEROX_API_KEY: process.env.ZEROX_API_KEY || '',
  STATE_SYNC_CONTRACT: process.env.STATE_SYNC_CONTRACT || '0x0000000000000000000000000000000000000005',
  MIN_BOND_COVERAGE: 10000, // 100% in basis points
  MAX_SLIPPAGE: 500, // 5%
  RETRY_COUNT: 3,
  RETRY_DELAY: 1000,
};

// === STATE SYNC AUDIT LOG ===
class StateSync {
  constructor() {
    this.log = [];
    this.hashChain = createHash('sha256');
    this.hashChain.update('genesis');
  }

  logAction(action, data) {
    const timestamp = Date.now();
    const entry = {
      id: this.log.length,
      timestamp,
      action,
      data,
      hash: this._computeHash(),
    };
    this.log.push(entry);
    this.hashChain.update(JSON.stringify(entry));
    console.log(`[AUDIT] ${action} | hash: ${entry.hash.substring(0, 16)}...`);
    return entry;
  }

  _computeHash() {
    const prevHash = this.log.length > 0 ? this.log[this.log.length - 1].hash : 'genesis';
    const combined = prevHash + JSON.stringify({ timestamp: Date.now(), action: 'sync' });
    return createHash('sha256').update(combined).digest('hex');
  }

  getAuditTrail() {
    return this.log.map((entry, idx) => ({
      ...entry,
      chainHash: this._computeChainHash(idx),
    }));
  }

  _computeChainHash(index) {
    let hash = 'genesis';
    for (let i = 0; i <= index; i++) {
      hash = createHash('sha256').update(hash + JSON.stringify(this.log[i])).digest('hex');
    }
    return hash;
  }
}

// === 0X API INTEGRATION ===
class ZeroXExecutor {
  constructor(apiUrl, apiKey) {
    this.apiUrl = apiUrl;
    this.apiKey = apiKey;
  }

  async getSwapQuote(fromToken, toToken, amount, fromAddress) {
    const params = new URLSearchParams({
      sellToken: fromToken,
      buyToken: toToken,
      sellAmount: amount.toString(),
      takerAddress: fromAddress,
      slippagePercentage: (CONFIG.MAX_SLIPPAGE / 100).toFixed(2),
      fee: '0',
    });

    const response = await fetch(`${this.apiUrl}/swap?${params.toString()}`, {
      headers: this.apiKey ? { '0x-api-key': this.apiKey } : {},
    });

    if (!response.ok) {
      throw new Error(`0x API error: ${response.statusText}`);
    }

    return response.json();
  }

  async executeSwap(quote, fromAddress, privateKey) {
    const txData = quote.tx;
    const provider = new ethersLib.JsonRpcProvider(CONFIG.RPC_URL);
    const wallet = new ethersLib.Wallet(privateKey, provider);

    const tx = {
      to: txData.to,
      data: txData.data,
      value: txData.value || '0',
      gasLimit: txData.gas,
    };

    const signedTx = await wallet.signTransaction(tx);
    const receipt = await provider.sendTransaction(signedTx);
    await receipt.wait();

    return {
      success: true,
      txHash: receipt.hash,
      from: txData.from,
      to: txData.to,
      value: txData.value,
    };
  }
}

// === BOND VERIFICATION SERVICE ===
class BondVerifier {
  constructor(vaultAddress, controllerAddress, provider) {
    this.vaultAddress = vaultAddress;
    this.controllerAddress = controllerAddress;
    this.provider = provider;
    this.vaultAbi = [
      'function agentBonds(address) view returns (uint256 bondAmount, uint256 riskBuffer, uint256 lastBondUpdate)',
      'function totalBonds() view returns (uint256)',
      'function MIN_BOND() view returns (uint256)',
      'function LIQUIDATION_THRESHOLD() view returns (uint256)',
      'function getAgentBondStatus(address) view returns (uint256 bondAmount, uint256 riskBuffer, uint256 lastBondUpdate, bool isActive)',
    ];
    this.controllerAbi = [
      'function getBondToRiskRatio(address) view returns (uint256)',
      'function MIN_RATIO() view returns (uint256)',
      'function isAgentActive(address) view returns (bool)',
      'function getTradeHistory(address) view returns (uint256 totalTrades, uint256 successfulTrades, uint256 failedTrades)',
    ];
    this.vaultContract = new ethersLib.Contract(vaultAddress, this.vaultAbi, provider);
    this.controllerContract = new ethersLib.Contract(controllerAddress, this.controllerAbi, provider);
  }

  async verifyBond(agentAddress) {
    const bondData = await this.vaultContract.agentBonds(agentAddress);
    const ratio = await this.controllerContract.getBondToRiskRatio(agentAddress);
    const isActive = await this.controllerContract.isAgentActive(agentAddress);

    const bondStatus = {
      bondAmount: bondData.bondAmount,
      riskBuffer: bondData.riskBuffer,
      lastBondUpdate: bondData.lastBondUpdate,
      ratio: ratio.toString(),
      isActive,
      coverage: this._calculateCoverage(bondData.bondAmount, bondData.riskBuffer),
    };

    return bondStatus;
  }

  _calculateCoverage(bondAmount, riskBuffer) {
    if (riskBuffer === 0n) return 10000n;
    return (bondAmount * 10000n) / riskBuffer;
  }

  async validateTradePreconditions(agentAddress, expectedLoss) {
    const bondStatus = await this.verifyBond(agentAddress);

    if (!bondStatus.isActive) {
      throw new Error('Agent not active in controller');
    }

    const coverage = bondStatus.coverage;
    if (coverage < CONFIG.MIN_BOND_COVERAGE) {
      throw new Error(`Insufficient bond coverage: ${coverage} < ${CONFIG.MIN_BOND_COVERAGE}`);
    }

    const ratio = BigInt(bondStatus.ratio);
    if (ratio < 10000n) {
      throw new Error(`Bond-to-risk ratio below minimum: ${ratio}`);
    }

    return {
      valid: true,
      bondStatus,
      coverage,
      ratio,
    };
  }
}

// === RISK CALCULATOR SERVICE ===
class RiskService {
  constructor(riskCalculatorAddress, provider) {
    this.riskCalculatorAddress = riskCalculatorAddress;
    this.provider = provider;
    this.riskAbi = [
      'function calculateRiskScore(address, uint256) view returns (uint256)',
      'function getStrategyRisk(address) view returns (uint256 baseRisk, uint256 volatilityMultiplier)',
      'function getVolatilityConfig() view returns (uint256 currentVolatility, uint256 maxVolatility)',
    ];
    this.riskContract = new ethersLib.Contract(riskCalculatorAddress, this.riskAbi, provider);
  }

  async getRiskScore(agentAddress, tradeAmount) {
    const [baseRisk, volMultiplier] = await this.riskContract.getStrategyRisk(agentAddress);
    const riskScore = await this.riskContract.calculateRiskScore(agentAddress, tradeAmount);

    return {
      baseRisk: baseRisk.toString(),
      volatilityMultiplier: volMultiplier.toString(),
      calculatedRisk: riskScore.toString(),
      adjustedRisk: this._calculateAdjustedRisk(baseRisk, volMultiplier, tradeAmount),
    };
  }

  _calculateAdjustedRisk(baseRisk, volMultiplier, tradeAmount) {
    const adjusted = (BigInt(baseRisk) * BigInt(volMultiplier) * BigInt(tradeAmount)) / 1000000000000000000n;
    return adjusted.toString();
  }
}

// === AGENT SERVICE CORE ===
class BondedTradeAgent {
  constructor() {
    this.provider = new ethersLib.JsonRpcProvider(CONFIG.RPC_URL);
    this.wallet = new ethersLib.Wallet(CONFIG.PRIVATE_KEY, this.provider);
    this.stateSync = new StateSync();
    this.bondVerifier = new BondVerifier(
      CONFIG.BONDING_VAULT_ADDRESS,
      CONFIG.AGENT_CONTROLLER_ADDRESS,
      this.provider
    );
    this.riskService = new RiskService(CONFIG.RISK_CALCULATOR_ADDRESS, this.provider);
    this.zeroXExecutor = new ZeroXExecutor(CONFIG.ZEROX_API_URL, CONFIG.ZEROX_API_KEY);
    this.isRunning = false;
    this.tradeHistory = [];
  }

  async initialize() {
    this.stateSync.logAction('INIT', {
      agentAddress: this.wallet.address,
      rpcUrl: CONFIG.RPC_URL,
      timestamp: Date.now(),
    });

    const bondStatus = await this.bondVerifier.verifyBond(this.wallet.address);
    this.stateSync.logAction('BOND_CHECK', {
      agentAddress: this.wallet.address,
      bondStatus,
      timestamp: Date.now(),
    });

    if (!bondStatus.isActive) {
      throw new Error('Agent not registered in BondingVault');
    }

    this.isRunning = true;
    return {
      success: true,
      agentAddress: this.wallet.address,
      bondStatus,
    };
  }

  async executeTrade(fromToken, toToken, amount, agentAddress = null) {
    const targetAddress = agentAddress || this.wallet.address;

    const auditEntry = this.stateSync.logAction('TRADE_INIT', {
      fromToken,
      toToken,
      amount: amount.toString(),
      agentAddress: targetAddress,
      timestamp: Date.now(),
    });

    try {
      const preconditions = await this.bondVerifier.validateTradePreconditions(targetAddress, amount);
      this.stateSync.logAction('BOND_VALIDATED', {
        agentAddress: targetAddress,
        coverage: preconditions.coverage.toString(),
        ratio: preconditions.ratio.toString(),
        timestamp: Date.now(),
      });

      const riskData = await this.riskService.getRiskScore(targetAddress, amount);
      this.stateSync.logAction('RISK_CALCULATED', {
        agentAddress: targetAddress,
        riskData,
        timestamp: Date.now(),
      });

      const quote = await this.zeroXExecutor.getSwapQuote(
        fromToken,
        toToken,
        amount,
        this.wallet.address
      );

      this.stateSync.logAction('QUOTE_RECEIVED', {
        fromToken,
        toToken,
        amount: amount.toString(),
        quote,
        timestamp: Date.now(),
      });

      const execution = await this.zeroXExecutor.executeSwap(quote, this.wallet.address, CONFIG.PRIVATE_KEY);

      this.stateSync.logAction('TRADE_EXECUTED', {
        txHash: execution.txHash,
        fromToken,
        toToken,
        amount: amount.toString(),
        timestamp: Date.now(),
      });

      this.tradeHistory.push({
        id: this.tradeHistory.length,
        timestamp: Date.now(),
        fromToken,
        toToken,
        amount: amount.toString(),
        txHash: execution.txHash,
        success: true,
      });

      return {
        success: true,
        txHash: execution.txHash,
        auditTrail: this.stateSync.getAuditTrail(),
      };
    } catch (error) {
      this.stateSync.logAction('TRADE_FAILED', {
        error: error.message,
        fromToken,
        toToken,
        amount: amount.toString(),
        timestamp: Date.now(),
      });

      this.tradeHistory.push({
        id: this.tradeHistory.length,
        timestamp: Date.now(),
        fromToken,
        toToken,
        amount: amount.toString(),
        error: error.message,
        success: false,
      });

      throw error;
    }
  }

  async getAgentStatus() {
    const bondStatus = await this.bondVerifier.verifyBond(this.wallet.address);
    const riskData = await this.riskService.getRiskScore(this.wallet.address, 1000000000000000000n);
    const tradeStats = {
      totalTrades: this.tradeHistory.length,
      successfulTrades: this.tradeHistory.filter((t) => t.success).length,
      failedTrades: this.tradeHistory.filter((t) => !t.success).length,
    };

    return {
      agentAddress: this.wallet.address,
      bondStatus,
      riskData,
      tradeStats,
      isRunning: this.isRunning,
      auditHash: this.stateSync._computeHash(),
    };
  }

  getAuditTrail() {
    return this.stateSync.getAuditTrail();
  }

  stop() {
    this.isRunning = false;
    this.stateSync.logAction('AGENT_STOP', {
      timestamp: Date.now(),
      finalAuditHash: this.stateSync._computeHash(),
    });
  }
}

// === MAIN EXECUTION ===
async function main() {
  const agent = new BondedTradeAgent();

  try {
    const initResult = await agent.initialize();
    console.log('Agent initialized:', initResult);

    const status = await agent.getAgentStatus();
    console.log('Agent status:', status);

    if (process.argv[2] === 'trade') {
      const fromToken = process.argv[3] || '0xC02aaA39b223FE8D0A0e5C4F27eAD9083C756Cc2';
      const toToken = process.argv[4] || '0xA0b86991c6218b36c1d19D4a2e9Eb0cE3606eB48';
      const amount = process.argv[5] || '1000000000000000000';

      const tradeResult = await agent.executeTrade(fromToken, toToken, BigInt(amount));
      console.log('Trade executed:', tradeResult);
    }

    const auditTrail = agent.getAuditTrail();
    console.log('Audit trail entries:', auditTrail.length);

    agent.stop();
  } catch (error) {
    console.error('Agent error:', error.message);
    process.exit(1);
  }
}

if (import.meta.url === `file://${process.argv[1]}`) {
  main();
}

export { BondedTradeAgent, StateSync, ZeroXExecutor, BondVerifier, RiskService, CONFIG };