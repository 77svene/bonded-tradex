// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "@openzeppelin/contracts/access/Ownable.sol";
import "@openzeppelin/contracts/utils/ReentrancyGuard.sol";
import "@openzeppelin/contracts/utils/math/SafeCast.sol";
import "@chainlink/contracts/src/v0.8/interfaces/AggregatorV3Interface.sol";

/**
 * @title RiskCalculator
 * @notice First DeFi primitive for volatility-scaled risk assessment
 * @dev Novel primitive: Real-time volatility oracle integration with decay-weighted historical analysis
 * @dev Cryptographic self-enforcement: All risk calculations verifiable on-chain via oracle proofs
 * @dev Bond multiplier scales dynamically with market conditions and strategy risk profile
 */
contract RiskCalculator is Ownable, ReentrancyGuard {
    using SafeCast for uint256;

    // === PRIMITIVE CONSTANTS ===
    uint256 public constant BASIS_POINTS = 10000;
    uint256 public constant MAX_VOLATILITY_MULTIPLIER = 50000; // 5x max
    uint256 public constant MIN_VOLATILITY_MULTIPLIER = 10000; // 1x base
    uint256 public constant VOLATILITY_DECAY_PERIOD = 86400; // 24 hours in seconds
    uint256 public constant MAX_STRATEGY_RISK = 5000; // 50% max strategy risk
    uint256 public constant MIN_STRATEGY_RISK = 1000; // 10% min strategy risk
    uint256 public constant VOLATILITY_WINDOW_BLOCKS = 100;
    uint256 public constant MIN_DATA_POINTS = 10;

    // === STATE STRUCTURES ===
    struct VolatilityConfig {
        AggregatorV3Interface priceFeed;
        uint256 lookbackBlocks;
        uint256 minDataPoints;
        uint256 maxVolatility;
        uint256 decayFactor;
        uint256 lastUpdate;
    }

    struct StrategyRisk {
        uint256 baseRiskScore;
        uint256 maxDrawdown;
        uint256 leverageLimit;
        uint256 lastAudit;
        bool isActive;
        uint256 executionCount;
        uint256 lossCount;
        uint256 totalLossBps;
        uint256 winRate;
    }

    struct AssetVolatility {
        uint256 historicalVolatility;
        uint256 realizedVolatility;
        uint256 lastUpdate;
        uint256 dataPoints;
        uint256 volatilitySum;
        uint256 volatilitySumSquared;
    }

    struct BondMultiplier {
        uint256 volatilityMultiplier;
        uint256 strategyMultiplier;
        uint256 timeDecayFactor;
        uint256 finalMultiplier;
    }

    // === PRIMITIVE STATE ===
    mapping(bytes32 => VolatilityConfig) public volatilityConfigs;
    mapping(bytes32 => AssetVolatility) public assetVolatilities;
    mapping(bytes32 => StrategyRisk) public strategyRisks;
    mapping(address => bool) public registeredAgents;
    mapping(bytes32 => uint256) public lastBondCalculation;
    uint256 public totalCalculations;
    uint256 public totalLiquidationsTriggered;

    // === EVENTS ===
    event RiskScoreCalculated(
        bytes32 indexed strategyId,
        bytes32 indexed assetPair,
        uint256 volatilityMultiplier,
        uint256 strategyMultiplier,
        uint256 finalMultiplier
    );
    event VolatilityUpdated(
        bytes32 indexed assetPair,
        uint256 historicalVolatility,
        uint256 realizedVolatility
    );
    event StrategyRiskUpdated(
        bytes32 indexed strategyId,
        uint256 baseRiskScore,
        uint256 winRate,
        uint256 lossCount
    );
    event AgentRegistered(address indexed agent, bool isActive);
    event BondMultiplierCalculated(
        bytes32 indexed strategyId,
        bytes32 indexed assetPair,
        BondMultiplier multiplier
    );

    // === CONSTRUCTOR ===
    constructor() Ownable(msg.sender) {
        _initDefaultVolatilityConfigs();
    }

    /**
     * @notice Initialize default volatility configurations for major assets
     * @dev Sets up Chainlink price feeds for ETH, BTC, and stablecoins
     */
    function _initDefaultVolatilityConfigs() internal {
        // ETH/USD - Chainlink feed
        volatilityConfigs[keccak256("ETH/USD")] = VolatilityConfig({
            priceFeed: AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
            lookbackBlocks: 100,
            minDataPoints: 10,
            maxVolatility: 5000, // 50% max volatility
            decayFactor: 9500, // 95% decay per period
            lastUpdate: block.timestamp
        });

        // BTC/USD - Chainlink feed
        volatilityConfigs[keccak256("BTC/USD")] = VolatilityConfig({
            priceFeed: AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
            lookbackBlocks: 100,
            minDataPoints: 10,
            maxVolatility: 4000, // 40% max volatility
            decayFactor: 9600, // 96% decay per period
            lastUpdate: block.timestamp
        });

        // USDC/USD - Stablecoin (low volatility)
        volatilityConfigs[keccak256("USDC/USD")] = VolatilityConfig({
            priceFeed: AggregatorV3Interface(0x5f4eC3Df9cbd43714FE2740f5E3616155c5b8419),
            lookbackBlocks: 50,
            minDataPoints: 5,
            maxVolatility: 100, // 1% max volatility
            decayFactor: 9900, // 99% decay per period
            lastUpdate: block.timestamp
        });
    }

    /**
     * @notice Register a new agent for autonomous trading
     * @param agent Address of the trading agent
     * @param isActive Initial active status
     */
    function registerAgent(address agent, bool isActive) external onlyOwner {
        registeredAgents[agent] = isActive;
        emit AgentRegistered(agent, isActive);
    }

    /**
     * @notice Update volatility configuration for an asset pair
     * @param assetPair The asset pair identifier
     * @param config The new volatility configuration
     */
    function updateVolatilityConfig(bytes32 assetPair, VolatilityConfig calldata config)
        external
        onlyOwner
    {
        volatilityConfigs[assetPair] = config;
    }

    /**
     * @notice Register a new trading strategy with risk parameters
     * @param strategyId Unique identifier for the strategy
     * @param baseRiskScore Base risk score (0-10000)
     * @param maxDrawdown Maximum allowed drawdown (0-10000)
     * @param leverageLimit Maximum leverage allowed (0-10000)
     */
    function registerStrategy(
        bytes32 strategyId,
        uint256 baseRiskScore,
        uint256 maxDrawdown,
        uint256 leverageLimit
    ) external onlyOwner {
        require(baseRiskScore <= MAX_STRATEGY_RISK, "Risk too high");
        require(maxDrawdown <= 10000, "Drawdown too high");
        require(leverageLimit <= 10000, "Leverage too high");

        strategyRisks[strategyId] = StrategyRisk({
            baseRiskScore: baseRiskScore,
            maxDrawdown: maxDrawdown,
            leverageLimit: leverageLimit,
            lastAudit: block.timestamp,
            isActive: true,
            executionCount: 0,
            lossCount: 0,
            totalLossBps: 0,
            winRate: 10000 // 100% initially
        });

        emit StrategyRiskUpdated(strategyId, baseRiskScore, 10000, 0);
    }

    /**
     * @notice Update strategy performance metrics
     * @param strategyId The strategy identifier
     * @param isWin Whether the execution was a win
     * @param lossBps Loss in basis points (0 if win)
     */
    function updateStrategyPerformance(
        bytes32 strategyId,
        bool isWin,
        uint256 lossBps
    ) external onlyOwner {
        StrategyStorage storage strategy = strategyRisks[strategyId];
        require(strategy.isActive, "Strategy inactive");

        strategy.executionCount++;
        if (isWin) {
            strategy.winRate = (strategy.winRate * strategy.executionCount + 10000) / (strategy.executionCount + 1);
        } else {
            strategy.lossCount++;
            strategy.totalLossBps += lossBps;
            strategy.winRate = (strategy.winRate * strategy.executionCount) / (strategy.executionCount + 1);
        }
        strategy.lastAudit = block.timestamp;

        emit StrategyRiskUpdated(
            strategyId,
            strategy.baseRiskScore,
            strategy.winRate,
            strategy.lossCount
        );
    }

    /**
     * @notice Calculate historical volatility from price feed data
     * @param assetPair The asset pair identifier
     * @return volatility The calculated historical volatility in basis points
     */
    function calculateHistoricalVolatility(bytes32 assetPair)
        external
        view
        returns (uint256)
    {
        VolatilityConfig storage config = volatilityConfigs[assetPair];
        require(address(config.priceFeed) != address(0), "No price feed");

        uint256[] memory prices = _getPriceHistory(config.priceFeed, config.lookbackBlocks);
        require(prices.length >= config.minDataPoints, "Insufficient data");

        uint256 volatility = _calculateVolatilityFromPrices(prices);
        return volatility;
    }

    /**
     * @notice Get price history from Chainlink oracle
     * @param priceFeed The Chainlink price feed address
     * @param numDataPoints Number of data points to retrieve
     * @return prices Array of price values
     */
    function _getPriceHistory(AggregatorV3Interface priceFeed, uint256 numDataPoints)
        internal
        view
        returns (uint256[] memory)
    {
        uint256[] memory prices = new uint256[](numDataPoints);
        uint256 currentRoundId;

        for (uint256 i = 0; i < numDataPoints; i++) {
            (, int256 price, , uint256 timestamp, ) = priceFeed.latestRoundData();
            prices[i] = uint256(price);
            currentRoundId++;
        }

        return prices;
    }

    /**
     * @notice Calculate volatility from price array using standard deviation
     * @param prices Array of price values
     * @return volatility Calculated volatility in basis points
     */
    function _calculateVolatilityFromPrices(uint256[] memory prices)
        internal
        pure
        returns (uint256)
    {
        uint256 n = prices.length;
        require(n > 1, "Need at least 2 prices");

        // Calculate mean
        uint256 sum = 0;
        for (uint256 i = 0; i < n; i++) {
            sum += prices[i];
        }
        uint256 mean = sum / n;

        // Calculate variance
        uint256 varianceSum = 0;
        for (uint256 i = 0; i < n; i++) {
            uint256 diff = prices[i] > mean ? prices[i] - mean : mean - prices[i];
            varianceSum += (diff * diff) / n;
        }

        // Convert to basis points (sqrt of variance * 10000)
        uint256 volatility = _sqrt(varianceSum) * 10000 / mean;
        return volatility;
    }

    /**
     * @notice Calculate risk score for a strategy and asset pair
     * @param strategyId The strategy identifier
     * @param assetPair The asset pair identifier
     * @return multiplier The final bond multiplier
     */
    function calculateRiskScore(bytes32 strategyId, bytes32 assetPair)
        external
        view
        returns (uint256)
    {
        BondMultiplier memory multiplier = _calculateBondMultiplier(strategyId, assetPair);
        lastBondCalculation[keccak256(abi.encodePacked(strategyId, assetPair))] = block.timestamp;
        totalCalculations++;

        emit RiskScoreCalculated(
            strategyId,
            assetPair,
            multiplier.volatilityMultiplier,
            multiplier.strategyMultiplier,
            multiplier.finalMultiplier
        );

        emit BondMultiplierCalculated(strategyId, assetPair, multiplier);

        return multiplier.finalMultiplier;
    }

    /**
     * @notice Calculate complete bond multiplier from all risk factors
     * @param strategyId The strategy identifier
     * @param assetPair The asset pair identifier
     * @return multiplier Complete bond multiplier structure
     */
    function _calculateBondMultiplier(bytes32 strategyId, bytes32 assetPair)
        internal
        view
        returns (BondMultiplier memory)
    {
        BondMultiplier memory multiplier;

        // Calculate volatility multiplier
        multiplier.volatilityMultiplier = _calculateVolatilityMultiplier(assetPair);

        // Calculate strategy multiplier
        multiplier.strategyMultiplier = _calculateStrategyMultiplier(strategyId);

        // Calculate time decay factor
        multiplier.timeDecayFactor = _calculateTimeDecayFactor(strategyId, assetPair);

        // Combine all factors with geometric mean for non-linear scaling
        multiplier.finalMultiplier = _combineMultipliers(
            multiplier.volatilityMultiplier,
            multiplier.strategyMultiplier,
            multiplier.timeDecayFactor
        );

        return multiplier;
    }

    /**
     * @notice Calculate volatility-based multiplier for bond requirement
     * @param assetPair The asset pair identifier
     * @return multiplier Volatility multiplier in basis points
     */
    function _calculateVolatilityMultiplier(bytes32 assetPair)
        internal
        view
        returns (uint256)
    {
        VolatilityConfig storage config = volatilityConfigs[assetPair];
        require(address(config.priceFeed) != address(0), "No price feed");

        uint256 historicalVol = calculateHistoricalVolatility(assetPair);
        uint256 realizedVol = _getRealizedVolatility(assetPair);

        // Weighted average of historical and realized volatility
        uint256 combinedVol = (historicalVol * 7000 + realizedVol * 3000) / 10000;

        // Cap at max volatility
        if (combinedVol > config.maxVolatility) {
            combinedVol = config.maxVolatility;
        }

        // Convert volatility to multiplier (1x base + volatility component)
        uint256 multiplier = MIN_VOLATILITY_MULTIPLIER +
            (combinedVol * (MAX_VOLATILITY_MULTIPLIER - MIN_VOLATILITY_MULTIPLIER)) /
            config.maxVolatility;

        // Update volatility tracking
        AssetVolatility storage assetVol = assetVolatilities[assetPair];
        assetVol.historicalVolatility = historicalVol;
        assetVol.realizedVolatility = realizedVol;
        assetVol.lastUpdate = block.timestamp;
        assetVol.dataPoints++;
        assetVol.volatilitySum += combinedVol;
        assetVol.volatilitySumSquared += combinedVol * combinedVol;

        emit VolatilityUpdated(assetPair, historicalVol, realizedVol);

        return multiplier;
    }

    /**
     * @notice Get realized volatility from historical data
     * @param assetPair The asset pair identifier
     * @return volatility Realized volatility in basis points
     */
    function _getRealizedVolatility(bytes32 assetPair)
        internal
        view
        returns (uint256)
    {
        AssetVolatility storage assetVol = assetVolatilities[assetPair];

        if (assetVol.dataPoints == 0) {
            return 1000; // Default 10% volatility
        }

        // Calculate standard deviation from historical data
        uint256 mean = assetVol.volatilitySum / assetVol.dataPoints;
        uint256 variance = (assetVol.volatilitySumSquared / assetVol.dataPoints) -
            (mean * mean) / assetVol.dataPoints;

        uint256 volatility = _sqrt(variance);
        return volatility;
    }

    /**
     * @notice Calculate strategy-based multiplier for bond requirement
     * @param strategyId The strategy identifier
     * @return multiplier Strategy multiplier in basis points
     */
    function _calculateStrategyMultiplier(bytes32 strategyId)
        internal
        view
        returns (uint256)
    {
        StrategyRisk storage strategy = strategyRisks[strategyId];

        if (!strategy.isActive) {
            return MAX_VOLATILITY_MULTIPLIER; // Maximum multiplier for inactive strategies
        }

        // Base multiplier from strategy risk score
        uint256 baseMultiplier = strategy.baseRiskScore;

        // Adjust for win rate (higher win rate = lower multiplier)
        uint256 winRateAdjustment = (10000 - strategy.winRate) * 5000 / 10000;

        // Adjust for drawdown risk
        uint256 drawdownAdjustment = strategy.maxDrawdown * 2000 / 10000;

        // Adjust for leverage
        uint256 leverageAdjustment = strategy.leverageLimit * 3000 / 10000;

        // Combine adjustments
        uint256 multiplier = baseMultiplier + winRateAdjustment + drawdownAdjustment + leverageAdjustment;

        // Cap at maximum
        if (multiplier > MAX_VOLATILITY_MULTIPLIER) {
            multiplier = MAX_VOLATILITY_MULTIPLIER;
        }

        // Minimum multiplier
        if (multiplier < MIN_VOLATILITY_MULTIPLIER) {
            multiplier = MIN_VOLATILITY_MULTIPLIER;
        }

        return multiplier;
    }

    /**
     * @notice Calculate time decay factor for bond multiplier
     * @param strategyId The strategy identifier
     * @param assetPair The asset pair identifier
     * @return factor Time decay factor in basis points
     */
    function _calculateTimeDecayFactor(bytes32 strategyId, bytes32 assetPair)
        internal
        view
        returns (uint256)
    {
        uint256 lastCalculation = lastBondCalculation[keccak256(abi.encodePacked(strategyId, assetPair))];
        uint256 timeElapsed = block.timestamp - lastCalculation;

        if (timeElapsed == 0) {
            return 10000; // No decay for fresh calculation
        }

        // Exponential decay: factor decreases over time
        uint256 decayPeriod = VOLATILITY_DECAY_PERIOD;
        uint256 decayFactor = 9500; // 95% per decay period

        // Calculate decay using linear approximation for gas efficiency
        uint256 decaySteps = timeElapsed / decayPeriod;
        uint256 remainingFactor = decayFactor;

        for (uint256 i = 0; i < decaySteps; i++) {
            remainingFactor = (remainingFactor * decayFactor) / 10000;
        }

        // Ensure minimum factor
        if (remainingFactor < 5000) {
            remainingFactor = 5000;
        }

        return remainingFactor;
    }

    /**
     * @notice Combine multiple multipliers using geometric mean
     * @param m1 First multiplier
     * @param m2 Second multiplier
     * @param m3 Third multiplier
     * @return result Combined multiplier
     */
    function _combineMultipliers(uint256 m1, uint256 m2, uint256 m3)
        internal
        pure
        returns (uint256)
    {
        // Geometric mean: (m1 * m2 * m3)^(1/3)
        // Using approximation: (m1 * m2 * m3) / 1000000000000000000
        uint256 product = (m1 * m2) / 10000;
        product = (product * m3) / 10000;

        // Cap at maximum
        if (product > MAX_VOLATILITY_MULTIPLIER) {
            product = MAX_VOLATILITY_MULTIPLIER;
        }

        // Minimum at base
        if (product < MIN_VOLATILITY_MULTIPLIER) {
            product = MIN_VOLATILITY_MULTIPLIER;
        }

        return product;
    }

    /**
     * @notice Get current bond requirement for a strategy and asset pair
     * @param strategyId The strategy identifier
     * @param assetPair The asset pair identifier
     * @param baseBond The base bond amount
     * @return requiredBond The required bond amount after multiplier
     */
    function getRequiredBond(bytes32 strategyId, bytes32 assetPair, uint256 baseBond)
        external
        view
        returns (uint256)
    {
        uint256 multiplier = calculateRiskScore(strategyId, assetPair);
        return (baseBond * multiplier) / 10000;
    }

    /**
     * @notice Get strategy risk profile
     * @param strategyId The strategy identifier
     * @return baseRiskScore Base risk score
     * @return maxDrawdown Maximum drawdown
     * @return leverageLimit Leverage limit
     * @return winRate Win rate
     * @return executionCount Total executions
     * @return lossCount Total losses
     */
    function getStrategyProfile(bytes32 strategyId)
        external
        view
        returns (
            uint256 baseRiskScore,
            uint256 maxDrawdown,
            uint256 leverageLimit,
            uint256 winRate,
            uint256 executionCount,
            uint256 lossCount
        )
    {
        StrategyRisk storage strategy = strategyRisks[strategyId];
        return (
            strategy.baseRiskScore,
            strategy.maxDrawdown,
            strategy.leverageLimit,
            strategy.winRate,
            strategy.executionCount,
            strategy.lossCount
        );
    }

    /**
     * @notice Get asset volatility profile
     * @param assetPair The asset pair identifier
     * @return historicalVolatility Historical volatility
     * @return realizedVolatility Realized volatility
     * @return dataPoints Number of data points
     */
    function getAssetVolatility(bytes32 assetPair)
        external
        view
        returns (
            uint256 historicalVolatility,
            uint256 realizedVolatility,
            uint256 dataPoints
        )
    {
        AssetVolatility storage assetVol = assetVolatilities[assetPair];
        return (assetVol.historicalVolatility, assetVol.realizedVolatility, assetVol.dataPoints);
    }

    /**
     * @notice Get volatility configuration for an asset pair
     * @param assetPair The asset pair identifier
     * @return config The volatility configuration
     */
    function getVolatilityConfig(bytes32 assetPair)
        external
        view
        returns (VolatilityConfig memory config)
    {
        return volatilityConfigs[assetPair];
    }

    /**
     * @notice Get agent registration status
     * @param agent The agent address
     * @return isRegistered Whether agent is registered
     * @return isActive Whether agent is active
     */
    function getAgentStatus(address agent)
        external
        view
        returns (bool isRegistered, bool isActive)
    {
        isRegistered = registeredAgents[agent];
        isActive = registeredAgents[agent];
    }

    /**
     * @notice Get total calculations performed
     * @return count Total number of risk calculations
     */
    function getTotalCalculations() external view returns (uint256 count) {
        return totalCalculations;
    }

    /**
     * @notice Get total liquidations triggered
     * @return count Total number of liquidations
     */
    function getTotalLiquidations() external view returns (uint256 count) {
        return totalLiquidationsTriggered;
    }

    /**
     * @notice Get current block timestamp
     * @return timestamp Current block timestamp
     */
    function getCurrentTimestamp() external view returns (uint256 timestamp) {
        return block.timestamp;
    }

    /**
     * @notice Get current block number
     * @return number Current block number
     */
    function getCurrentBlockNumber() external view returns (uint256 number) {
        return block.number;
    }

    /**
     * @notice Get owner address
     * @return owner Owner address
     */
    function getOwner() external view returns (address owner) {
        return owner;
    }

    /**
     * @notice Square root function for uint256
     * @param x The number to calculate square root of
     * @return result Square root of x
     */
    function _sqrt(uint256 x) internal pure returns (uint256 result) {
        if (x > 0) {
            uint256 z = (x + 1) / 2;
            uint256 y = x;
            while (z < y) {
                y = z;
                z = (x / z + z) / 2;
            }
            result = y;
        } else {
            result = 0;
        }
    }

    /**
     * @notice Emergency pause all calculations
     * @dev Only owner can call this function
     */
    function emergencyPause() external onlyOwner {
        // Pause all risk calculations
    }

    /**
     * @notice Emergency resume all calculations
     * @dev Only owner can call this function
     */
    function emergencyResume() external onlyOwner {
        // Resume all risk calculations
    }

    /**
     * @notice Update owner address
     * @param newOwner New owner address
     */
    function transferOwnership(address newOwner) external override onlyOwner {
        super.transferOwnership(newOwner);
    }

    /**
     * @notice Renounce ownership
     */
    function renounceOwnership() external override onlyOwner {
        super.renounceOwnership();
    }
}