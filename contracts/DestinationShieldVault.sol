// SPDX-License-Identifier: MIT
pragma solidity ^0.8.24;

import "./interfaces/IReactiveOmni.sol";

/**
 * @title DestinationShieldVault
 * @author Tung Nguyen (@tungdeptrai07)
 * @notice Destination-chain autonomous DeFi protection vault deployed on Base Sepolia (84532).
 *
 *         Inherits `AbstractCallback(callbackProxy, reactiveSentinel)` and enforces:
 *         1. Dual callback auth: `onlyServiceProvider` AND `onlyCallbackSender(reactive_)`.
 *         2. Base Sepolia 200ms block rule compliance: strictly uses `block.timestamp` for all
 *            cooldowns and latency measurements (NEVER `block.number`).
 *         3. Real DeFi position accounting: shifts exposed volatile collateral into safe USDC shield
 *            reserves and lowers leverage debt ratio on stop-loss (actionType 1) or hedges 40% on
 *            volatility rebalance (actionType 2).
 */
contract DestinationShieldVault is AbstractCallback {
    uint8 public constant ACTION_STOP_LOSS_DELEVERAGE = 1;
    uint8 public constant ACTION_VOLATILITY_REBALANCE = 2;

    struct AssetVaultState {
        uint256 activeVolatileCollateralUSD; // Exposed LP / leveraged collateral (8 decimals)
        uint256 shieldedReserveUSD;          // Safe stablecoin shield reserve (8 decimals)
        uint256 debtUSD;                     // Outstanding borrow debt (8 decimals)
        uint256 lastProtectedAt;             // UNIX timestamp (Base Sepolia 200ms safe)
        uint256 lastObservedPriceE8;
        uint256 lastRiskScoreBps;
        uint256 protectionCount;
    }

    struct ExecutionRecord {
        address asset;
        uint256 observedPriceE8;
        uint256 volatilityBps;
        uint256 riskScoreBps;
        uint8 actionType;
        uint256 originTimestamp;
        uint256 callbackTimestamp;
        uint256 fullLoopLatencySec;
        uint256 shieldedAmountUSD;
        uint256 debtReducedUSD;
    }

    address public owner;
    uint256 public minProtectionCooldownSec;
    mapping(address => AssetVaultState) public vaults;
    ExecutionRecord[] public executionHistory;

    event PositionOpened(
        address indexed asset,
        uint256 activeCollateralUSD,
        uint256 debtUSD,
        uint256 timestamp
    );

    event PositionProtected(
        address indexed reactiveSender,
        address indexed asset,
        uint8 indexed actionType,
        uint256 observedPriceE8,
        uint256 riskScoreBps,
        uint256 shieldedAmountUSD,
        uint256 debtReducedUSD,
        uint256 fullLoopLatencySec
    );

    event PositionRebalancedToActive(address indexed asset, uint256 restoredAmountUSD, uint256 timestamp);

    modifier onlyOwner() {
        require(msg.sender == owner, "Only owner");
        _;
    }

    constructor(
        address callbackProxy_,
        address reactiveSentinel_,
        uint256 minProtectionCooldownSec_
    ) payable AbstractCallback(callbackProxy_, reactiveSentinel_) {
        owner = msg.sender;
        minProtectionCooldownSec = minProtectionCooldownSec_;
    }

    /**
     * @notice Seeds or expands a leveraged DeFi vault position for an asset (e.g. WETH / UNI).
     */
    function openOrFundPosition(
        address asset,
        uint256 collateralUSD,
        uint256 debtUSD
    ) external onlyOwner {
        require(asset != address(0), "Zero asset");
        require(collateralUSD > 0, "Collateral must be positive");
        require(debtUSD < collateralUSD, "Position would start underwater");

        AssetVaultState storage st = vaults[asset];
        st.activeVolatileCollateralUSD += collateralUSD;
        st.debtUSD += debtUSD;

        emit PositionOpened(asset, st.activeVolatileCollateralUSD, st.debtUSD, block.timestamp);
    }

    /**
     * @notice Restores shielded reserve back into active yield position after market calms down.
     */
    function restoreShieldedReserve(address asset, uint256 amountUSD) external onlyOwner {
        AssetVaultState storage st = vaults[asset];
        require(amountUSD > 0 && amountUSD <= st.shieldedReserveUSD, "Invalid restore amount");
        st.shieldedReserveUSD -= amountUSD;
        st.activeVolatileCollateralUSD += amountUSD;
        emit PositionRebalancedToActive(asset, amountUSD, block.timestamp);
    }

    /**
     * @notice Autonomous Reactive Omni callback entrypoint.
     *         First parameter `reactive_` is injected by Reactive Omni / Callback Proxy.
     */
    function executeProtection(
        address reactive_,
        address asset,
        uint256 observedPriceE8,
        uint256 volatilityBps,
        uint256 riskScoreBps,
        uint8 actionType,
        uint256 originTimestamp
    ) external onlyServiceProvider onlyCallbackSender(reactive_) {
        require(asset != address(0), "Zero asset");
        require(
            actionType == ACTION_STOP_LOSS_DELEVERAGE || actionType == ACTION_VOLATILITY_REBALANCE,
            "Unsupported action type"
        );

        AssetVaultState storage st = vaults[asset];
        require(st.activeVolatileCollateralUSD > 0, "No active collateral to protect");

        // Strictly timestamp-based cooldown (safe for Base Sepolia 200ms block cadence)
        if (minProtectionCooldownSec > 0 && st.lastProtectedAt != 0) {
            require(
                block.timestamp >= st.lastProtectedAt + minProtectionCooldownSec,
                "Destination vault timestamp cooldown active"
            );
        }

        uint256 shieldedAmountUSD;
        uint256 debtReducedUSD;

        if (actionType == ACTION_STOP_LOSS_DELEVERAGE) {
            // Emergency stop-loss: unwind 80% of volatile exposure & repay 75% of debt
            shieldedAmountUSD = (st.activeVolatileCollateralUSD * 80) / 100;
            debtReducedUSD = (st.debtUSD * 75) / 100;
        } else {
            // Volatility hedge: shift 40% of volatile exposure into USDC reserve & trim 30% debt
            shieldedAmountUSD = (st.activeVolatileCollateralUSD * 40) / 100;
            debtReducedUSD = (st.debtUSD * 30) / 100;
        }

        st.activeVolatileCollateralUSD -= shieldedAmountUSD;
        st.shieldedReserveUSD += shieldedAmountUSD;
        st.debtUSD -= debtReducedUSD;
        st.lastProtectedAt = block.timestamp;
        st.lastObservedPriceE8 = observedPriceE8;
        st.lastRiskScoreBps = riskScoreBps;
        st.protectionCount += 1;

        uint256 latencySec = block.timestamp >= originTimestamp
            ? block.timestamp - originTimestamp
            : 0;

        executionHistory.push(
            ExecutionRecord({
                asset: asset,
                observedPriceE8: observedPriceE8,
                volatilityBps: volatilityBps,
                riskScoreBps: riskScoreBps,
                actionType: actionType,
                originTimestamp: originTimestamp,
                callbackTimestamp: block.timestamp,
                fullLoopLatencySec: latencySec,
                shieldedAmountUSD: shieldedAmountUSD,
                debtReducedUSD: debtReducedUSD
            })
        );

        emit PositionProtected(
            reactive_,
            asset,
            actionType,
            observedPriceE8,
            riskScoreBps,
            shieldedAmountUSD,
            debtReducedUSD,
            latencySec
        );
    }

    function getExecutionCount() external view returns (uint256) {
        return executionHistory.length;
    }

    function getHealthFactorBps(address asset) external view returns (uint256) {
        AssetVaultState memory st = vaults[asset];
        uint256 totalAssets = st.activeVolatileCollateralUSD + st.shieldedReserveUSD;
        if (st.debtUSD == 0) return type(uint256).max;
        return (totalAssets * 10_000) / st.debtUSD;
    }
}
