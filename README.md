# OmniSentinel RSC — Sub-Second Cross-Chain DeFi Stop-Loss & Volatility Shield on Reactive Omni

[![Solidity](https://img.shields.io/badge/Solidity-0.8.24%2B-38bdf8?style=flat-square)](https://soliditylang.org)
[![Reactive Omni](https://img.shields.io/badge/Reactive%20Omni-0x8888...8888-818cf8?style=flat-square)](https://dev.reactive.network)
[![Tests](https://img.shields.io/badge/EVM%20Tests-100%25%20Passing-34d399?style=flat-square)](#running-tests)

**Hackathon:** [Reactive Omni Buildathon](https://dorahacks.io/hackathon/reactive-omni-buildathon/detail) (`$5,500 REACT`)  
**Primary Track:** **Every Second Counts** (`Unichain Sepolia 1301` &rarr; `Reactive Lasna 5318007` &rarr; `Base Sepolia 84532`)  
**Pitch Deck:** [`SLIDES.pdf`](./SLIDES.pdf) | **Organizer Q&A Prep:** [`DORAHACKS_ANSWERS.md`](./DORAHACKS_ANSWERS.md)

---

## Native Reactive Omni Architecture

`OmniSentinel RSC` is engineered directly against the **Reactive Omni specification** (`dev.reactive.network`), replacing off-chain keeper bots with deterministic on-chain cross-chain callbacks:

| Layer | Network | Chain ID | Contract | Official Reactive Proxy / System |
|---|---|---|---|---|
| **Origin** | Unichain Sepolia (1s blocks) | `1301` | [`OriginMarketOracle.sol`](./contracts/OriginMarketOracle.sol) | `0x775c9B990ADe401060B78D0e98684eEf8d2466C1` |
| **Reactive** | Reactive Lasna (~1s finality) | `5318007` | [`OmniSentinelReactive.sol`](./contracts/OmniSentinelReactive.sol) | `0x8888888888888888888888888888888888888888` |
| **Destination** | Base Sepolia (200ms blocks) | `84532` | [`DestinationShieldVault.sol`](./contracts/DestinationShieldVault.sol) | `0x476F44b11F5C942c58f4c8E3d0300E5710743585` |

### Key Reactive Omni Compliance Highlights
1. **No Legacy RVM Hacks:** Drops deprecated `vm` / `vmOnly` dual-state; inherits `AbstractReactive` with `onlySystem` bound directly to `0x8888888888888888888888888888888888888888`.
2. **Omni Callback Standard:** Dispatches callbacks via `SYSTEM.requestCallbackV_1_0(CallbackConfiguration_V_1_0({ chainId, recipient, gasLimit, payload }))`.
3. **First-Argument Injection Rule:** Encodes `address(0)` as the first parameter of `executeProtection(address reactive_, ...)` so Reactive Omni overwrites the first 160 bits with `address(OmniSentinelReactive)`.
4. **Dual Callback Authorization:** `DestinationShieldVault.executeProtection` enforces **both** `onlyServiceProvider` (`msg.sender == callbackProxy`) **and** `onlyCallbackSender(reactive_)` (`reactive_ == callbackSender`).
5. **Base Sepolia 200ms Block Rule:** 100% of cooldowns and full-loop latency measurements use `block.timestamp` (zero reliance on `block.number`).
6. **Debt & Funding Lifecycle:** Both `OmniSentinelReactive` and `DestinationShieldVault` implement `AbstractPayer` (`receive()`, `pay(uint256)`, `coverDebt()`).

---

## Quick Start, Compilation & EVM Tests

```bash
# 1. Install dependencies (solc, ethers v6, ganache EVM)
npm install

# 2. Compile all Solidity contracts cleanly with solc
npm run compile

# 3. Run full real EVM + HTTP API test suite
npm test

# 4. Launch interactive EVM dashboard (http://127.0.0.1:8098)
npm run serve

# 5. Deploy live to Unichain Sepolia + Reactive Lasna + Base Sepolia & measure real full-loop latency
PRIVATE_KEY=0x... npm run deploy:testnet
```

## License

MIT License.
