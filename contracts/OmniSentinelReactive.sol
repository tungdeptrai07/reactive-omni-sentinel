// SPDX-License-Identifier: MIT
pragma solidity ^0.8.20;

/**
 * @title IReactive
 * @notice Official Reactive Network Interface for Event-Driven Smart Contracts (RSC).
 */
interface IReactive {
    struct LogRecord {
        uint256 chain_id;
        address _contract;
        uint256 topic_0;
        uint256 topic_1;
        uint256 topic_2;
        uint256 topic_3;
        bytes data;
        uint256 block_number;
        uint256 op_code;
        uint256 block_hash;
        uint256 tx_hash;
        uint256 log_index;
    }

    event Callback(
        uint256 indexed chain_id,
        address indexed _contract,
        uint64 indexed gas_limit,
        bytes payload
    );

    function react(LogRecord calldata log) external;
}

/**
 * @title OmniSentinelReactive
 * @author Tung Nguyen (@tungdeptrai07)
 * @notice Autonomous Cross-Chain DeFi Stop-Loss, Liquidation Shield & AI Yield Router
 *         built for the Reactive Omni Buildathon (Unichain Sepolia <-> Base Sepolia).
 */
contract OmniSentinelReactive is IReactive {
    uint256 public constant UNICHAIN_SEPOLIA_ID = 1301;
    uint256 public constant BASE_SEPOLIA_ID = 84532;
    uint64 public constant CALLBACK_GAS_LIMIT = 250000;

    // Keccak-256 signature of PriceOracleUpdated(address indexed asset, uint256 newPrice, uint256 volatilityBps)
    uint256 public constant PRICE_ORACLE_TOPIC_0 =
        0x7c42879b4a0717a7a88e0619820a86f2321255b708531b530e9248224f1a09d2;

    address public owner;
    address public originOracleContract;
    address public destinationVaultContract;
    uint256 public stopLossThresholdUSD; // 8 decimals (e.g. 2000_00000000 = $2,000)
    uint256 public totalCallbacksDispatched;

    event GuardTriggered(
        uint256 indexed originChain,
        uint256 indexed destChain,
        uint256 observedPrice,
        uint256 volatilityBps,
        bytes callbackPayload
    );

    constructor(
        address _originOracle,
        address _destinationVault,
        uint256 _stopLossThresholdUSD
    ) {
        owner = msg.sender;
        originOracleContract = _originOracle;
        destinationVaultContract = _destinationVault;
        stopLossThresholdUSD = _stopLossThresholdUSD;
    }

    /**
     * @notice Inversion-of-Control entrypoint invoked autonomously by the Reactive Network
     *         whenever a subscribed event log is emitted on the origin chain.
     */
    function react(LogRecord calldata log) external override {
        // 1. Verify origin contract & event signature topic_0
        if (log._contract != originOracleContract) return;
        if (log.topic_0 != PRICE_ORACLE_TOPIC_0) return;

        // 2. Decode non-indexed event data: (uint256 newPrice, uint256 volatilityBps)
        (uint256 observedPrice, uint256 volatilityBps) = abi.decode(log.data, (uint256, uint256));

        // 3. Evaluate autonomous Stop-Loss OR High-Volatility AI Rebalance condition
        if (observedPrice <= stopLossThresholdUSD || volatilityBps >= 850) {
            address asset = address(uint160(log.topic_1));
            bytes memory payload = abi.encodeWithSignature(
                "executeEmergencyDeleverage(address,uint256,uint256)",
                asset,
                observedPrice,
                volatilityBps
            );

            totalCallbacksDispatched += 1;

            // 4. Emit Callback to execute transaction on Destination Chain (Base Sepolia / Unichain)
            emit Callback(
                BASE_SEPOLIA_ID,
                destinationVaultContract,
                CALLBACK_GAS_LIMIT,
                payload
            );

            emit GuardTriggered(
                log.chain_id,
                BASE_SEPOLIA_ID,
                observedPrice,
                volatilityBps,
                payload
            );
        }
    }
}
