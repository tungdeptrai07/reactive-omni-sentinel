// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

/**
 * @title OriginMarketOracle
 * @author Tung Nguyen (@tungdeptrai07)
 * @notice Origin-chain market telemetry emitter deployed on Unichain Sepolia (chainId 1301).
 *         Emits timestamped price, volatility (bps), and liquidity depth events monitored
 *         autonomously by `OmniSentinelReactive` on Reactive Lasna (5318007).
 */
contract OriginMarketOracle {
    struct MarketSnapshot {
        uint256 priceE8;
        uint256 volatilityBps;
        uint256 liquidityDepthUSD;
        uint256 updatedAt;
    }

    address public owner;
    mapping(address => bool) public authorizedReporters;
    mapping(address => MarketSnapshot) public latestSnapshots;
    uint256 public totalUpdatesEmitted;

    event PriceVolatilityAlert(
        address indexed asset,
        uint256 priceE8,
        uint256 volatilityBps,
        uint256 liquidityDepthUSD,
        uint256 emittedAt
    );

    event ReporterUpdated(address indexed reporter, bool authorized);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    modifier onlyReporter() {
        require(msg.sender == owner || authorizedReporters[msg.sender], "Only authorized reporter");
        _;
    }

    constructor() {
        owner = msg.sender;
        authorizedReporters[msg.sender] = true;
    }

    function setReporter(address reporter, bool authorized) external onlyOwner {
        require(reporter != address(0), "Zero reporter");
        authorizedReporters[reporter] = authorized;
        emit ReporterUpdated(reporter, authorized);
    }

    /**
     * @notice Publishes a new market snapshot and emits `PriceVolatilityAlert` with `block.timestamp`
     *         so downstream Base Sepolia callbacks can measure exact end-to-end Reactive Omni latency.
     */
    function publishMarketSnapshot(
        address asset,
        uint256 priceE8,
        uint256 volatilityBps,
        uint256 liquidityDepthUSD
    ) external onlyReporter {
        require(asset != address(0), "Zero asset");
        require(priceE8 > 0, "Price must be positive");
        require(volatilityBps <= 10_000, "Volatility bps out of range");

        latestSnapshots[asset] = MarketSnapshot({
            priceE8: priceE8,
            volatilityBps: volatilityBps,
            liquidityDepthUSD: liquidityDepthUSD,
            updatedAt: block.timestamp
        });

        totalUpdatesEmitted += 1;

        emit PriceVolatilityAlert(
            asset,
            priceE8,
            volatilityBps,
            liquidityDepthUSD,
            block.timestamp
        );
    }
}
