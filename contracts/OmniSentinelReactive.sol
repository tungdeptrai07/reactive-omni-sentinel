// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IReactiveOmni.sol";

/**
 * @title OmniSentinelReactive
 * @author Tung Nguyen (@tungdeptrai07)
 * @notice Reactive Omni Smart Contract (RSC) deployed on Reactive Lasna (5318007) / Mainnet (1597).
 *
 *         Subscribes to `PriceVolatilityAlert` on Unichain Sepolia (1301), evaluates an on-chain
 *         deterministic risk engine (price drop vs stop-loss + volatility bps + liquidity thinning),
 *         enforces timestamp-based anti-spam cooldowns, and dispatches `SYSTEM.requestCallbackV_1_0`
 *         to `DestinationShieldVault` on Base Sepolia (84532) with `address(0)` in the first argument
 *         slot so Reactive Omni injects this contract's address cleanly.
 */
contract OmniSentinelReactive is AbstractReactive {
    uint256 public constant DEFAULT_UNICHAIN_SEPOLIA_ID = 1301;
    uint256 public constant DEFAULT_BASE_SEPOLIA_ID = 84532;
    uint64 public constant CALLBACK_GAS_LIMIT = 400_000;

    /// @notice Action codes dispatched to DestinationShieldVault
    uint8 public constant ACTION_STOP_LOSS_DELEVERAGE = 1;
    uint8 public constant ACTION_VOLATILITY_REBALANCE = 2;

    /// @notice Exact keccak256 topic0 of PriceVolatilityAlert(address,uint256,uint256,uint256,uint256)
    uint256 public constant PRICE_ALERT_TOPIC_0 = uint256(
        keccak256("PriceVolatilityAlert(address,uint256,uint256,uint256,uint256)")
    );

    address public owner;
    uint256 public originChainId;
    uint256 public destinationChainId;
    address public originOracle;
    address public destinationVault;

    uint256 public stopLossThresholdE8;      // e.g. 2000_00000000 ($2,000.00)
    uint256 public maxVolatilityBps;         // e.g. 750 (7.50% intraday shock)
    uint256 public minLiquidityDepthUSD;     // e.g. 500_000 ($500k minimum pool depth)
    uint256 public riskScoreTriggerBps;      // e.g. 6500 (65.00% composite risk triggers hedge)
    uint256 public cooldownSeconds;          // Timestamp-based cooldown (never block count!)

    bool public paused;
    uint256 public totalEventsProcessed;
    uint256 public totalCallbacksRequested;
    mapping(address => uint256) public lastTriggerTimestamp;

    event SentinelRiskEvaluated(
        address indexed asset,
        uint256 priceE8,
        uint256 volatilityBps,
        uint256 liquidityDepthUSD,
        uint256 riskScoreBps,
        uint8 actionType,
        bool callbackDispatched
    );

    event SentinelConfigUpdated(
        uint256 stopLossThresholdE8,
        uint256 maxVolatilityBps,
        uint256 minLiquidityDepthUSD,
        uint256 riskScoreTriggerBps,
        uint256 cooldownSeconds
    );

    event DestinationVaultUpdated(address indexed previousVault, address indexed newVault);
    event PausedStateChanged(bool paused);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(
        address systemOverride_,
        uint256 originChainId_,
        uint256 destinationChainId_,
        address originOracle_,
        address destinationVault_,
        uint256 stopLossThresholdE8_,
        uint256 maxVolatilityBps_,
        uint256 minLiquidityDepthUSD_,
        uint256 cooldownSeconds_
    ) payable AbstractReactive(systemOverride_) {
        require(originOracle_ != address(0), "Origin oracle required");
        require(stopLossThresholdE8_ > 0, "Stop-loss threshold must be positive");

        owner = msg.sender;
        originChainId = originChainId_ == 0 ? DEFAULT_UNICHAIN_SEPOLIA_ID : originChainId_;
        destinationChainId = destinationChainId_ == 0 ? DEFAULT_BASE_SEPOLIA_ID : destinationChainId_;
        originOracle = originOracle_;
        destinationVault = destinationVault_;
        stopLossThresholdE8 = stopLossThresholdE8_;
        maxVolatilityBps = maxVolatilityBps_ == 0 ? 750 : maxVolatilityBps_;
        minLiquidityDepthUSD = minLiquidityDepthUSD_ == 0 ? 500_000 : minLiquidityDepthUSD_;
        riskScoreTriggerBps = 6500;
        cooldownSeconds = cooldownSeconds_;

        // Subscribe on Reactive Omni System Contract (0x8888...8888) immediately at deployment
        SYSTEM.subscribe(
            originChainId,
            originOracle,
            PRICE_ALERT_TOPIC_0,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE,
            REACTIVE_IGNORE
        );
    }

    /**
     * @notice Sets the destination vault address after cross-chain deployment pairing
     *         (since DestinationShieldVault needs this RSC address in its constructor).
     */
    function setDestinationVault(address newVault) external onlyOwner {
        require(newVault != address(0), "Zero vault address");
        address prev = destinationVault;
        destinationVault = newVault;
        emit DestinationVaultUpdated(prev, newVault);
    }

    function updateRiskConfig(
        uint256 stopLossThresholdE8_,
        uint256 maxVolatilityBps_,
        uint256 minLiquidityDepthUSD_,
        uint256 riskScoreTriggerBps_,
        uint256 cooldownSeconds_
    ) external onlyOwner {
        require(stopLossThresholdE8_ > 0, "Invalid stop-loss");
        require(riskScoreTriggerBps_ <= 10_000, "Invalid risk score threshold");
        stopLossThresholdE8 = stopLossThresholdE8_;
        maxVolatilityBps = maxVolatilityBps_;
        minLiquidityDepthUSD = minLiquidityDepthUSD_;
        riskScoreTriggerBps = riskScoreTriggerBps_;
        cooldownSeconds = cooldownSeconds_;

        emit SentinelConfigUpdated(
            stopLossThresholdE8_,
            maxVolatilityBps_,
            minLiquidityDepthUSD_,
            riskScoreTriggerBps_,
            cooldownSeconds_
        );
    }

    function setPaused(bool paused_) external onlyOwner {
        paused = paused_;
        emit PausedStateChanged(paused_);
    }

    /**
     * @notice Pure deterministic composite risk scoring model (0..10000 bps):
     *         - Price Breach Weight: up to 5000 bps when price <= stopLossThresholdE8
     *         - Volatility Shock Weight: up to 3500 bps scaled against maxVolatilityBps
     *         - Liquidity Thinning Weight: up to 1500 bps when pool depth falls below minLiquidityDepthUSD
     */
    function computeRiskScoreBps(
        uint256 priceE8,
        uint256 volatilityBps,
        uint256 liquidityDepthUSD
    ) public view returns (uint256 riskScoreBps) {
        uint256 priceScore = 0;
        if (priceE8 <= stopLossThresholdE8) {
            uint256 deficit = stopLossThresholdE8 - priceE8;
            uint256 extra = (deficit * 2000) / stopLossThresholdE8;
            priceScore = 3500 + (extra > 1500 ? 1500 : extra);
        } else {
            uint256 marginBps = ((priceE8 - stopLossThresholdE8) * 10_000) / stopLossThresholdE8;
            if (marginBps < 500) {
                priceScore = ((500 - marginBps) * 2000) / 500;
            }
        }

        uint256 volScore = maxVolatilityBps == 0
            ? 0
            : (volatilityBps * 3500) / maxVolatilityBps;
        if (volScore > 3500) volScore = 3500;

        uint256 liqScore = 0;
        if (minLiquidityDepthUSD > 0 && liquidityDepthUSD < minLiquidityDepthUSD) {
            liqScore = ((minLiquidityDepthUSD - liquidityDepthUSD) * 1500) / minLiquidityDepthUSD;
        }

        riskScoreBps = priceScore + volScore + liqScore;
        if (riskScoreBps > 10_000) riskScoreBps = 10_000;
    }

    /**
     * @inheritdoc IReactive
     * @notice Reactive Omni entrypoint invoked exclusively by `SYSTEM` (`0x8888...8888`).
     */
    function react(LogRecord memory log_) external override onlySystem {
        if (paused) return;
        if (destinationVault == address(0)) return;
        if (log_.chain_id != originChainId) return;
        if (log_._contract != originOracle) return;
        if (log_.topic_0 != PRICE_ALERT_TOPIC_0) return;

        totalEventsProcessed += 1;

        address asset = address(uint160(log_.topic_1));
        (uint256 priceE8, uint256 volatilityBps, uint256 liquidityDepthUSD, uint256 emittedAt) =
            abi.decode(log_.data, (uint256, uint256, uint256, uint256));

        uint256 riskScoreBps = computeRiskScoreBps(priceE8, volatilityBps, liquidityDepthUSD);

        uint8 actionType = 0;
        if (priceE8 <= stopLossThresholdE8) {
            actionType = ACTION_STOP_LOSS_DELEVERAGE;
        } else if (volatilityBps >= maxVolatilityBps || riskScoreBps >= riskScoreTriggerBps) {
            actionType = ACTION_VOLATILITY_REBALANCE;
        }

        if (actionType == 0) {
            emit SentinelRiskEvaluated(
                asset,
                priceE8,
                volatilityBps,
                liquidityDepthUSD,
                riskScoreBps,
                0,
                false
            );
            return;
        }

        // Timestamp-based anti-spam cooldown (strictly block.timestamp, never block.number)
        if (
            cooldownSeconds > 0 &&
            lastTriggerTimestamp[asset] != 0 &&
            block.timestamp < lastTriggerTimestamp[asset] + cooldownSeconds
        ) {
            emit SentinelRiskEvaluated(
                asset,
                priceE8,
                volatilityBps,
                liquidityDepthUSD,
                riskScoreBps,
                actionType,
                false
            );
            return;
        }

        lastTriggerTimestamp[asset] = block.timestamp;
        totalCallbacksRequested += 1;

        // First parameter MUST be address(0): Reactive Omni overwrites it with address(this)
        bytes memory payload = abi.encodeWithSignature(
            "executeProtection(address,address,uint256,uint256,uint256,uint8,uint256)",
            address(0),
            asset,
            priceE8,
            volatilityBps,
            riskScoreBps,
            actionType,
            emittedAt
        );

        SYSTEM.requestCallbackV_1_0(
            ISystemContract.CallbackConfiguration_V_1_0({
                chainId: destinationChainId,
                recipient: destinationVault,
                gasLimit: CALLBACK_GAS_LIMIT,
                payload: payload
            })
        );

        emit SentinelRiskEvaluated(
            asset,
            priceE8,
            volatilityBps,
            liquidityDepthUSD,
            riskScoreBps,
            actionType,
            true
        );
    }
}
