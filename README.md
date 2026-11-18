# OmniSentinel RSC — Cross-Chain DeFi Stop-Loss & AI Rebalancer on Reactive Network

**Hackathon:** Reactive Omni Buildathon ($5,500 Prize Pool)  
**Contracts:** [`contracts/OmniSentinelReactive.sol`](contracts/OmniSentinelReactive.sol)  
**Chains:** Unichain Sepolia (`1301`) &harr; Reactive Network &harr; Base Sepolia (`84532`)

## Overview
**OmniSentinel RSC** implements the `IReactive` standard (`react(LogRecord calldata log)`) to eliminate centralized off-chain keepers. When an oracle or liquidity pool on Unichain Sepolia emits a price drop or volatility spike, `OmniSentinelReactive.sol` autonomously dispatches a cross-chain `Callback` event to deleverage and protect positions on Base Sepolia.
