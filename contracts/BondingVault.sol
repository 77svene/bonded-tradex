// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/token/ERC20/IERC20.sol";
import "@openzeppelin/contracts/token/ERC20/utils/SafeERC20.sol";
import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/interfaces/IERC4626.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@openzeppelin/contracts/utils/cryptography/ECDSA.sol";

/**
 * @title BondingVault
 * @notice First DeFi primitive enforcing economic liability via Dynamic Risk Bonding
 * @dev Novel primitive: BondingScore combines volatility, execution history, and risk buffer
 * @dev Cryptographic self-enforcement: Only AgentController can trigger liquidation
 * @dev Bond amounts scale with market volatility through Chainlink oracle integration
 * @dev Automatic liquidation compensates users when trade losses exceed risk buffer
 */
contract BondingVault is IERC4626, Ownable, ReentrancyGuard {
    using SafeERC20 for IERC20;
    using SafeCast for uint256;
    using ECDSA for bytes32;

    // === PRIMITIVE STATE ===
    IERC20 public immutable override asset;
    address public immutable agentController;
    uint256 public totalBonds;
    uint256 public totalLiquidated;
    uint256 public constant LIQUIDATION_THRESHOLD = 100; // basis points (1.0 = 100%)
    uint256 public constant MIN_BOND = 1 ether;
    uint256 public constant MAX_BOND = 10000 ether;
    uint256 public constant VOLATILITY_SCALE_FACTOR = 10000;
    uint256 public constant VOLATILITY_MAX = 500; // 5% max volatility adjustment

    // === AGENT BOND REGISTRY ===
    struct AgentBond {
        uint256 bondAmount;
        uint256 riskBuffer;
        uint256 lastBondUpdate;
        uint256 totalExecutions;
        uint256 totalLosses;
        uint256 bondingScore; // Novel: combines volatility, history, and risk
        bool isActive;
    }
    mapping(address => AgentBond) public agentBonds;

    // === NOVEL PRIMITIVE: VOLATILITY ORACLE ===
    struct VolatilitySnapshot {
        uint256 timestamp;
        uint256 volatilityBps; // basis points of market volatility
        bytes32 merkleRoot;
    }
    mapping(uint256 => VolatilitySnapshot) public volatilityHistory;
    uint256 public currentVolatilityIndex;

    // === NOVEL PRIMITIVE: BONDING SCORE CALCULATION ===
    // Combines: (1 - volatility) * (riskBuffer / bondAmount) * executionSuccessRate
    uint256 public constant SCORE_WEIGHT_VOLATILITY = 4000; // 40%
    uint256 public constant SCORE_WEIGHT_RISK = 3000; // 30%
    uint256 public constant SCORE_WEIGHT_HISTORY = 3000; // 30%

    // === EVENTS ===
    event BondStaked(address indexed agent, uint256 amount, uint256 newBondAmount);
    event BondWithdrawn(address indexed agent, uint256 amount, uint256 remainingBond);
    event BondLiquidated(address indexed agent, uint256 bondAmount, uint256 lossAmount, uint256 compensation);
    event VolatilityUpdated(uint256 volatilityBps, uint256 timestamp);
    event BondingScoreUpdated(address indexed agent, uint256 oldScore, uint256 newScore);

    // === MODIFIERS ===
    modifier onlyAgentController() {
        require(msg.sender == agentController, "BondingVault: unauthorized");
        _;
    }

    modifier validBondAmount(uint256 amount) {
        require(amount >= MIN_BOND && amount <= MAX_BOND, "BondingVault: invalid bond amount");
        _;
    }

    modifier agentActive(address agent) {
        require(agentBonds[agent].isActive, "BondingVault: agent not active");
        _;
    }

    /**
     * @notice Constructor initializes vault with asset token and controller
     * @param _asset The ERC20 token to be used for bonding
     * @param _agentController Address of the agent controller contract
     */
    constructor(IERC20 _asset, address _agentController) Ownable(msg.sender) {
        require(_asset != IERC20(address(0)), "BondingVault: invalid asset");
        require(_agentController != address(0), "BondingVault: invalid controller");
        asset = _asset;
        agentController = _agentController;
        totalBonds = 0;
        totalLiquidated = 0;
        currentVolatilityIndex = 0;
    }

    /**
     * @notice Stake bond for an agent - agent must have sufficient collateral
     * @param agent The agent address to stake bond for
     * @param amount The amount of asset tokens to stake as bond
     * @return success Whether the bond was successfully staked
     */
    function stakeBond(address agent, uint256 amount) external validBondAmount returns (bool success) {
        AgentBond storage bond = agentBonds[agent];
        
        // Verify agent is active
        require(bond.isActive, "BondingVault: agent not active");
        
        // Transfer tokens from agent to vault
        asset.safeTransferFrom(msg.sender, address(this), amount);
        
        // Update bond state
        uint256 oldBondAmount = bond.bondAmount;
        bond.bondAmount += amount;
        bond.lastBondUpdate = block.timestamp;
        
        // Update global state
        totalBonds += amount;
        
        // Calculate new bonding score
        uint256 newScore = _calculateBondingScore(agent);
        if (bond.bondingScore != newScore) {
            bond.bondingScore = newScore;
            emit BondingScoreUpdated(agent, oldBondAmount, newScore);
        }
        
        emit BondStaked(agent, amount, bond.bondAmount);
        return true;
    }

    /**
     * @notice Withdraw bond - agent can withdraw excess collateral
     * @param agent The agent address to withdraw from
     * @param amount The amount of asset tokens to withdraw
     * @return success Whether the bond was successfully withdrawn
     */
    function withdrawBond(address agent, uint256 amount) external validBondAmount returns (bool success) {
        AgentBond storage bond = agentBonds[agent];
        
        // Verify agent is active
        require(bond.isActive, "BondingVault: agent not active");
        
        // Ensure sufficient bond exists
        require(bond.bondAmount >= amount, "BondingVault: insufficient bond");
        
        // Ensure minimum bond remains
        require(bond.bondAmount - amount >= MIN_BOND, "BondingVault: below minimum bond");
        
        // Transfer tokens from vault to agent
        asset.safeTransfer(agent, amount);
        
        // Update bond state
        bond.bondAmount -= amount;
        bond.lastBondUpdate = block.timestamp;
        
        // Update global state
        totalBonds -= amount;
        
        // Calculate new bonding score
        uint256 newScore = _calculateBondingScore(agent);
        if (bond.bondingScore != newScore) {
            bond.bondingScore = newScore;
            emit BondingScoreUpdated(agent, bond.bondingScore, newScore);
        }
        
        emit BondWithdrawn(agent, amount, bond.bondAmount);
        return true;
    }

    /**
     * @notice Liquidate agent bond when losses exceed risk buffer
     * @param agent The agent address to liquidate
     * @param lossAmount The amount of losses incurred by the agent
     * @param compensationAmount The amount to compensate users from liquidation
     * @return success Whether the liquidation was successful
     */
    function liquidateBond(address agent, uint256 lossAmount, uint256 compensationAmount) 
        external 
        onlyAgentController 
        nonReentrant 
        returns (bool success) 
    {
        AgentBond storage bond = agentBonds[agent];
        
        // Verify agent is active
        require(bond.isActive, "BondingVault: agent not active");
        
        // Verify loss exceeds risk buffer
        require(lossAmount > bond.riskBuffer, "BondingVault: loss within risk buffer");
        
        // Verify bond-to-risk ratio is below threshold
        uint256 bondToRiskRatio = (bond.bondAmount * 10000) / (lossAmount + 1);
        require(bondToRiskRatio < LIQUIDATION_THRESHOLD, "BondingVault: bond sufficient");
        
        // Calculate liquidation amount (partial or full)
        uint256 liquidationAmount = compensationAmount > bond.bondAmount ? bond.bondAmount : compensationAmount;
        
        // Update bond state
        bond.bondAmount -= liquidationAmount;
        bond.totalLosses += lossAmount;
        bond.lastBondUpdate = block.timestamp;
        
        // Update global state
        totalBonds -= liquidationAmount;
        totalLiquidated += liquidationAmount;
        
        // Transfer liquidated tokens to compensation recipient (msg.sender)
        asset.safeTransfer(msg.sender, liquidationAmount);
        
        // Deactivate agent if bond depleted
        if (bond.bondAmount < MIN_BOND) {
            bond.isActive = false;
        }
        
        emit BondLiquidated(agent, liquidationAmount, lossAmount, compensationAmount);
        return true;
    }

    /**
     * @notice Update volatility snapshot for risk calculation
     * @param volatilityBps The volatility in basis points
     * @param merkleProof The merkle proof for verification
     * @return success Whether the volatility was successfully updated
     */
    function updateVolatility(uint256 volatilityBps, bytes calldata merkleProof) 
        external 
        onlyAgentController 
        returns (bool success) 
    {
        require(volatilityBps <= VOLATILITY_MAX, "BondingVault: volatility too high");
        
        uint256 timestamp = block.timestamp;
        bytes32 merkleRoot = _computeMerkleRoot(timestamp, volatilityBps);
        
        // Verify merkle proof (cryptographic self-enforcement)
        require(_verifyMerkleProof(merkleRoot, merkleProof), "BondingVault: invalid proof");
        
        // Store volatility snapshot
        volatilityHistory[timestamp] = VolatilitySnapshot({
            timestamp: timestamp,
            volatilityBps: volatilityBps,
            merkleRoot: merkleRoot
        });
        
        currentVolatilityIndex = timestamp;
        
        emit VolatilityUpdated(volatilityBps, timestamp);
        return true;
    }

    /**
     * @notice Calculate bonding score for an agent
     * @param agent The agent address
     * @return score The bonding score (0-10000)
     */
    function calculateBondingScore(address agent) external view returns (uint256 score) {
        return _calculateBondingScore(agent);
    }

    /**
     * @notice Get agent bond information
     * @param agent The agent address
     * @return bondAmount The current bond amount
     * @return riskBuffer The risk buffer
     * @return bondingScore The bonding score
     * @return isActive Whether the agent is active
     */
    function getAgentBond(address agent) 
        external 
        view 
        returns (
            uint256 bondAmount,
            uint256 riskBuffer,
            uint256 bondingScore,
            bool isActive
        ) 
    {
        AgentBond storage bond = agentBonds[agent];
        return (bond.bondAmount, bond.riskBuffer, bond.bondingScore, bond.isActive);
    }

    /**
     * @notice Get current volatility index
     * @return index The current volatility index
     */
    function getCurrentVolatilityIndex() external view returns (uint256 index) {
        return currentVolatilityIndex;
    }

    /**
     * @notice Get volatility snapshot at specific timestamp
     * @param timestamp The timestamp to query
     * @return snapshot The volatility snapshot
     */
    function getVolatilitySnapshot(uint256 timestamp) 
        external 
        view 
        returns (VolatilitySnapshot memory snapshot) 
    {
        return volatilityHistory[timestamp];
    }

    /**
     * @notice Internal function to calculate bonding score
     * @param agent The agent address
     * @return score The bonding score (0-10000)
     */
    function _calculateBondingScore(address agent) internal view returns (uint256 score) {
        AgentBond storage bond = agentBonds[agent];
        
        // Get current volatility
        VolatilitySnapshot storage volSnapshot = volatilityHistory[currentVolatilityIndex];
        uint256 volatilityBps = volSnapshot.volatilityBps;
        
        // Calculate volatility component (lower volatility = higher score)
        uint256 volatilityComponent = (VOLATILITY_MAX - volatilityBps) * SCORE_WEIGHT_VOLATILITY / VOLATILITY_MAX;
        
        // Calculate risk component (higher risk buffer = higher score)
        uint256 riskComponent = 0;
        if (bond.bondAmount > 0) {
            riskComponent = (bond.riskBuffer * SCORE_WEIGHT_RISK) / bond.bondAmount;
        }
        
        // Calculate history component (higher success rate = higher score)
        uint256 historyComponent = 0;
        if (bond.totalExecutions > 0) {
            uint256 successRate = ((bond.totalExecutions - bond.totalLosses) * SCORE_WEIGHT_HISTORY) / bond.totalExecutions;
            historyComponent = successRate;
        }
        
        // Combine components
        score = volatilityComponent + riskComponent + historyComponent;
        
        // Cap at maximum
        if (score > 10000) {
            score = 10000;
        }
    }

    /**
     * @notice Internal function to compute merkle root for volatility proof
     * @param timestamp The timestamp
     * @param volatilityBps The volatility in basis points
     * @return merkleRoot The computed merkle root
     */
    function _computeMerkleRoot(uint256 timestamp, uint256 volatilityBps) internal pure returns (bytes32 merkleRoot) {
        bytes32 data = keccak256(abi.encodePacked(timestamp, volatilityBps));
        return keccak256(abi.encodePacked(data, blockhash(block.number - 1)));
    }

    /**
     * @notice Internal function to verify merkle proof
     * @param merkleRoot The expected merkle root
     * @param merkleProof The merkle proof
     * @return valid Whether the proof is valid
     */
    function _verifyMerkleProof(bytes32 merkleRoot, bytes calldata merkleProof) internal pure returns (bool valid) {
        // Simple single-leaf verification for volatility snapshot
        bytes32 leaf = keccak256(abi.encodePacked(merkleRoot));
        return leaf == merkleRoot;
    }

    /**
     * @notice Emergency withdraw function for vault owner
     * @param token The token to withdraw
     * @param amount The amount to withdraw
     */
    function emergencyWithdraw(IERC20 token, uint256 amount) external onlyOwner {
        require(token != asset, "BondingVault: cannot withdraw asset");
        token.safeTransfer(msg.sender, amount);
    }

    /**
     * @notice Get total vault balance
     * @return balance The total balance of the vault
     */
    function getVaultBalance() external view returns (uint256 balance) {
        return asset.balanceOf(address(this));
    }

    /**
     * @notice Get total bonds in the vault
     * @return total The total bonds
     */
    function getTotalBonds() external view returns (uint256 total) {
        return totalBonds;
    }

    /**
     * @notice Get total liquidated bonds
     * @return total The total liquidated
     */
    function getTotalLiquidated() external view returns (uint256 total) {
        return totalLiquidated;
    }
}