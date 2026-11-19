# Reactive Omni Buildathon — DoraHacks Submission Answers Prep

> **IMPORTANT EXECUTION GATE REMINDER (DO NOT SKIP BEFORE SUBMITTING):**  
> Reactive Omni judges strictly require **real on-chain Reactive Lasna / Mainnet deployed addresses and full-loop transaction hashes** (`Origin -> Reactive -> Callback`) — *"We want to see the reactive transactions and the callbacks they trigger on-chain. Entries without them aren't scored further."*  
> Run `PRIVATE_KEY=0x... npm run deploy:testnet` once testnet gas (`Unichain Sepolia ETH`, `Base Sepolia ETH`, `Lasna lREACT`) is funded, then paste the resulting values from `deployment_proof.json` into Questions 1–3 below before submitting!

---

### 1. Deployed contract addresses, and which network (Reactive mainnet or Lasna)?
- **Network:** Reactive Lasna Testnet (`chainId 5318007`) + Unichain Sepolia (`1301`) + Base Sepolia (`84532`)
- **OriginMarketOracle (Unichain Sepolia `1301`):** `<FILL FROM deployment_proof.json>`
- **OmniSentinelReactive (Reactive Lasna `5318007`, bound to `SYSTEM 0x8888...8888`):** `<FILL FROM deployment_proof.json>`
- **DestinationShieldVault (Base Sepolia `84532`, proxy `0x476F44b11F5C942c58f4c8E3d0300E5710743585`):** `<FILL FROM deployment_proof.json>`

### 2. Transaction hashes showing the full loop, from origin event to callback.
- **Origin Event TX (Unichain Sepolia `publishMarketSnapshot`):** `<FILL FROM deployment_proof.json>`
- **Reactive Execution TX (Reactive Lasna `react` + `requestCallbackV_1_0`):** `<FILL FROM Lasna Explorer>`
- **Destination Callback TX (Base Sepolia `executeProtection`):** `<FILL FROM Base Sepolia Explorer>`

### 3. For Every Second Counts: what full-loop latency did you measure, and how?
- **Measurement Method:** `OriginMarketOracle.publishMarketSnapshot()` embeds `block.timestamp` (`emittedAt`) inside `PriceVolatilityAlert`. `OmniSentinelReactive.react()` forwards `emittedAt` inside the `requestCallbackV_1_0` payload, and `DestinationShieldVault.executeProtection()` records `fullLoopLatencySec = block.timestamp - originTimestamp` on-chain while `scripts/deploy_and_measure.mjs` records exact wall-clock milliseconds from origin receipt confirmation to Base Sepolia `getExecutionCount() > 0`.
- **Measured Result:** `<FILL measuredWallClockMs & onChainLatencySec FROM deployment_proof.json>`

### 4. Was this your first time building with Reactive? Your first smart contract?
- First time building directly on **Reactive Omni** (`SYSTEM 0x8888...8888`, `requestCallbackV_1_0`, dropping legacy `vmOnly`). Not our first smart contract — we have prior Solidity, Stylus/Rust, and Bitcoin Cash CashScript experience.

### 5. What was the hardest part of building with Reactive?
- Migrating cleanly from older Reactive Network v1 examples (which relied on `0x...fffFfF`, `vmOnly`, and `emit Callback`) to the **Reactive Omni** standard (`0x8888...8888`, `onlySystem`, `requestCallbackV_1_0`), ensuring the first 160-bit payload argument placeholder (`address(0)`) is accurately overwritten and verified via dual-auth (`onlyServiceProvider` + `onlyCallbackSender`), and enforcing strict `block.timestamp` cooldowns for Base Sepolia's 200ms block cadence.

### 6. How did you hear about the buildathon?
- Discovered via DoraHacks (`https://dorahacks.io/hackathon/reactive-omni-buildathon/detail`).
