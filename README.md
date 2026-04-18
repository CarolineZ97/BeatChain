# BeatChain

> **Decentralized Music Royalty Investment Platform** — Deployed on Polygon

BeatChain is a Polygon-based decentralized platform for music royalty investment. Artists tokenize their streaming royalty rights as ERC-20 tokens and sell them to investors; investors receive monthly USDC royalty distributions proportional to their holdings. A multi-node Oracle network brings verified off-chain royalty data on-chain, an SPV trust handles fiat-to-USDC conversion, and a Uniswap v3 liquidity pool supports secondary market trading.

---

## Project Architecture

```
BeatChain/
├── contracts/
│   ├── interfaces/
│   │   ├── IMusicToken.sol          # MusicToken interface
│   │   ├── IOracle.sol              # Oracle interface (incl. ZK-ML structs)
│   │   └── IRoyaltyDistributor.sol  # Royalty distribution interface
│   ├── MusicToken.sol               # Per-song ERC-20 token contract
│   ├── RoyaltyDistributor.sol       # Royalty distribution (Pull model)
│   ├── OracleConsumer.sol           # Multi-node Oracle + median consensus
│   ├── ListingManager.sol           # Song listing lifecycle management
│   ├── EscrowVault.sol              # Artist security deposit escrow
│   ├── DelistingManager.sol         # Delisting monitoring and execution
│   ├── PriceFeed.sol                # DCF fair value storage
│   ├── PlatformTreasury.sol         # Platform fee treasury
│   └── MockERC20.sol                # Mock USDC contract for testing
├── scripts/
│   ├── deploy.js                    # Deploy all contracts in dependency order
│   ├── mockOracle.js                # Simulate Oracle monthly data submissions
│   └── mockIssuance.js              # Simulate full song listing and token purchase
├── test/
│   └── beatchain.test.js            # Full test suite (7 core scenarios)
├── hardhat.config.js
├── .env.example
└── README.md
```

---

## Contract Responsibilities

| Contract | Responsibility |
|----------|----------------|
| `MusicToken.sol` | Per-song ERC-20 token. Stores: total supply, artist wallet, royalty share sold, and issuance fair value. One instance deployed per song. |
| `RoyaltyDistributor.sol` | Receives USDC from the SPV trust. Deducts 1% platform fee. Records each holder's claimable balance. Uses Pull model (holders claim actively). |
| `OracleConsumer.sol` | Accepts royalty data submissions from whitelisted Oracle nodes. Computes the median across all submissions. Rejects submissions deviating >20% (slashes stake). Triggers `RoyaltyDistributor` once data passes validation. |
| `ListingManager.sol` | Manages song listing lifecycle: PENDING, ACTIVE, DELISTED. Stores eligibility criteria. Calls `EscrowVault` to lock artist deposit at listing time. |
| `EscrowVault.sol` | Locks artist security deposit in USDC at listing. Automatically distributes deposit to token holders if artist defaults (2 consecutive months without transfer). Returns deposit to artist on clean delisting. |
| `DelistingManager.sol` | Monitors `PriceFeed` fair value monthly. Triggers delisting review if fair value stays below 30% of issuance price for 6 consecutive months. Handles both voluntary and forced delisting. |
| `PriceFeed.sol` | Stores DCF fair value per token, updated monthly by Oracle. Readable by `DelistingManager` and the frontend. |
| `PlatformTreasury.sol` | Receives platform fees (3% issuance fee + 1% distribution fee). Only the platform admin wallet may withdraw. |

---

## Key Business Parameters

| Parameter | Value |
|-----------|-------|
| Platform issuance fee | 3% of fundraising amount |
| Platform distribution fee | 1% of monthly royalties |
| Artist minimum retention | 50% royalty rights (max 50% sellable) |
| Artist security deposit | 30%–50% of projected annual royalty income |
| Oracle deviation threshold | 20% (submissions beyond this are rejected) |
| Oracle minimum node count | 3 nodes required for consensus |
| Monthly update safeguard | Fair value change >25% triggers manual review flag |
| Delisting trigger | Fair value below 30% of issuance price for 6 consecutive months |
| Artist default trigger | 2 consecutive months without royalty transfer |
| Settlement currency | USDC (ERC-20, Polygon address) |
| Blockchain | Polygon (Mumbai testnet for development) |
| Token standard | ERC-20 |

---

## Contract Interaction Map

```
ListingManager
    → calls EscrowVault.lockDeposit()           at listing
    → deploys new MusicToken                    per song

OracleConsumer
    → calls PriceFeed.updateFairValue()         after data passes validation
    → calls RoyaltyDistributor.receiveRoyalty() to trigger distribution
    → calls DelistingManager.recordMonth()      with validated income data

RoyaltyDistributor
    → reads MusicToken.balanceOf()              to compute each holder's share
    → calls PlatformTreasury.depositFee()       for the 1% fee

DelistingManager
    → reads PriceFeed.getFairValue()            monthly
    → calls EscrowVault.distributeToHolders()   on confirmed default
    → calls ListingManager.setStatus(DELISTED)  on confirmed delisting
```

---

## Deployment Order

Contracts have dependencies and must be deployed in the following order:

1. `PlatformTreasury`
2. `EscrowVault` (requires USDC address)
3. `PriceFeed`
4. `ListingManager` (requires EscrowVault address)
5. `RoyaltyDistributor` (requires PlatformTreasury address)
6. `OracleConsumer` (requires RoyaltyDistributor + PriceFeed addresses)
7. `DelistingManager` (requires PriceFeed + EscrowVault + ListingManager addresses)

---

## Quick Start

### 1. Install Dependencies

```bash
cd BeatChain
npm install
```

### 2. Configure Environment Variables

```bash
cp .env.example .env
# Edit .env with your private key and RPC URL
```

### 3. Start Local Node

```bash
npm run node
```

### 4. Deploy Contracts (Local)

```bash
npm run deploy:local
```

### 5. Run Simulation Scripts

```bash
# Simulate song listing and token purchase
npm run mock:issuance

# Simulate Oracle monthly data submissions
npm run mock:oracle
```

### 6. Run Tests

```bash
npm test
```

### 7. Deploy to Mumbai Testnet

```bash
npm run deploy:mumbai
```

---

## Test Coverage

| # | Scenario | Description |
|---|----------|-------------|
| 1 | Song token deployment | Validates total supply, artist share, royalty ratio cap |
| 2 | Token purchase | Validates holder balance, 3% issuance fee, 97% to artist |
| 3 | Oracle data submission | Validates median calculation (odd/even submissions), minimum node requirement |
| 4 | Oracle outlier rejection | Validates >20% deviation is rejected and node is slashed |
| 5 | Royalty distribution | Validates 1% platform fee, proportional distribution, Pull-model claiming |
| 6 | Artist default | Validates 2 consecutive missed payments trigger default and deposit distribution to holders |
| 7 | Forced delisting | Validates 6 consecutive months below 30% fair value triggers delisting |

---

## ZK-ML Oracle Architecture

This project implements the ZK-ML (Zero-Knowledge Machine Learning) Oracle architecture described in the system documentation:

1. **Off-chain computation (Prover):** Oracle nodes run ML models (Ridge Regression / DNN) off-chain to derive expected royalty amounts, then generate cryptographic proofs using zk-SNARKs.

2. **On-chain verification (Verifier):** `OracleConsumer.sol` accepts royalty data alongside ZK proofs and validates authenticity through a median consensus mechanism.

3. **Anomaly circuit breaker:** If the actual settled amount deviates from the predicted amount by more than 20%, the Oracle rejects the submission and slashes the node's stake. If deviation exceeds 30%, a circuit breaker is triggered — distribution for that month is paused and a 72-hour manual audit period begins.

4. **Decentralized verification:** The contract only needs to verify the validity of the ZK proof to confirm the off-chain ML computation was not tampered with — achieving "decentralized verification of a centralized algorithm."

---

## CeDeFi Fund Flow

```
Investor USDC
    ↓ purchase tokens
MusicToken.sol
    ├── 3% → PlatformTreasury.sol
    └── 97% → Artist wallet

DistroKid royalties (fiat)
    ↓ auto-converted
SPV Trust account (Circle / Stripe)
    ↓ converted to USDC
OracleConsumer.sol (validation)
    ↓ triggers distribution
RoyaltyDistributor.sol
    ├── 1% → PlatformTreasury.sol
    └── 99% → Investor claimable balance (Pull model)
```

---

## License

MIT License
