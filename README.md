<div align="center">

# MoveGate Protocol

**Safely onboard autonomous agents into your Sui protocol.**

Bounded permissions, on-chain reputation and immutable audit trails.
No private key sharing. One function call to integrate.

[![contracts](https://img.shields.io/badge/move-contracts-blue?style=flat-square)](https://github.com/hamzzaaamalik/movegate-contracts)
[![sdk](https://img.shields.io/npm/v/@movegate/sdk?style=flat-square&label=sdk&color=blue)](https://www.npmjs.com/package/@movegate/sdk)
[![license](https://img.shields.io/badge/license-MIT-green?style=flat-square)](https://github.com/hamzzaaamalik/movegate-contracts/blob/main/LICENSE)
![tests](https://img.shields.io/badge/tests-83%20passed-brightgreen?style=flat-square)
![coverage](https://img.shields.io/badge/coverage-96.66%25-brightgreen?style=flat-square)
![sui](https://img.shields.io/badge/sui-1.67.2-purple?style=flat-square)

[Website](https://movegate.xyz) · [Smart Contracts](https://github.com/hamzzaaamalik/movegate-contracts) · [TypeScript SDK](https://github.com/hamzzaaamalik/movegate-sdk) · [npm](https://www.npmjs.com/package/@movegate/sdk)

</div>

---

## Why MoveGate Exists

Autonomous agents are the next execution layer for DeFi. They rebalance portfolios, execute trades, manage DAO treasuries and optimize yields. But today every agent requires either full wallet access (catastrophic risk) or constant manual approval (defeats the purpose of automation).

There is no trust layer. No way to verify whether an agent has operated reliably across 10,000 transactions or whether it was deployed yesterday. No way to grant scoped permissions that the agent cannot exceed. No way to prove what happened after the fact.

MoveGate solves this with four primitives enforced at the Move type-system level:

| Primitive | What It Does |
|---|---|
| **AgentPassport** | Permanent on-chain identity for every agent. Auto-created on first action. Free. Never deleted. |
| **Mandate** | Bounded permission object. Scoped by protocol, coin type, amount, time and action type. |
| **AuthToken** | Hot-potato token with zero Move abilities. Must be consumed in the same transaction. Cannot be stored, copied or dropped. |
| **ActionReceipt** | Frozen on-chain record of every action. Immutable. Cryptographic proof of history. |

## The Four-Layer Stack

```
+----------------------------------------------------------------------+
|  Layer          Module           Purpose              Moat            |
+----------------------------------------------------------------------+
|                                                                      |
|  Identity       passport.move    Permanent agent      Agent behavior |
|                                  identity. Auto-      dataset that   |
|                                  created. Score       compounds      |
|                                  0-1000.              daily.         |
|                                                                      |
|  Authorization  mandate.move     Bounded permissions  Hot-potato     |
|                                  enforced at type-    AuthToken      |
|                                  system level.        makes bypass   |
|                                                       impossible.    |
|                                                                      |
|  Audit          receipt.move     Frozen receipts.     Every receipt  |
|                                  Immutable proof      feeds the      |
|                                  of every action.     identity layer.|
|                                                                      |
|  Economics      treasury.move    Micro-fee on every   Revenue scales |
|                                  authorized action.   with ecosystem |
|                                  Admin-controlled.    volume.        |
|                                                                      |
+----------------------------------------------------------------------+
```

These four layers create a system where authorization cannot be bypassed, history cannot be faked, data cannot be replicated and revenue grows with ecosystem adoption.

## Architecture

Six Move modules. Zero external dependencies beyond the Sui framework.

```
errors.move       Centralized error codes (35 constants, 7 categories)
    |
events.move       Typed event structs (11 types, package-private emitters)
    |
treasury.move     Fee collection + AdminCap + ProtocolTreasury
    |
passport.move     AgentPassport + AgentRegistry + reputation scoring engine
    |
mandate.move      Mandate + AuthToken (hot potato) + 10-check authorization gate
    |
receipt.move      ActionReceipt (frozen immutable objects via transfer::freeze_object)
```

### Module Dependency Graph

```
errors          events            (no dependencies)
  |               |
  v               v
treasury      passport            (depend on errors, events)
    \           /
     \         /
      v       v
      mandate                     (depends on errors, events, treasury, passport)
         |
         v
      receipt                     (depends on events, mandate, passport)
```

**Critical design decision:** `passport.move` has no dependency on `mandate.move`. The identity layer is independent of the authorization layer. Agents can have a passport before any mandate exists. Protocols can query passport data without integrating mandate authorization. The identity layer can be upgraded independently.

## How It Works

### Step 1: Agent Gets a Passport (Automatic, Free)

The first time an agent interacts with MoveGate, an `AgentPassport` is created automatically. No registration. No fee. No friction. The passport is a shared object that persists permanently on-chain.

```
register_agent(registry, clock, ctx)
```

`register_agent` is the public entry point. It calls `ensure_passport` internally (which is `public(package)` to prevent external spoofing). Idempotent. Safe to call multiple times.

Every subsequent action updates the passport: total volume, success rate, unique protocols, consecutive streaks. This data feeds the reputation score.

### Step 2: User Creates a Mandate

A user grants bounded permissions by creating a `Mandate` that specifies exactly what the agent can do.

```
create_mandate(
    agent:             0xAGENT,
    spend_cap:         500_000_000,       // max per transaction (0.5 SUI)
    daily_limit:       2_000_000_000,     // max per epoch (2 SUI)
    allowed_protocols: [NAVI_ADDR],       // only NAVI
    allowed_coin_types:[type_of<SUI>()],  // only SUI
    allowed_actions:   [1, 2],            // deposit + withdraw only
    expires_at_ms:     now + 30 days,
    min_agent_score:   Some(700),         // require reputation >= 700
    payment:           fee_coin,          // 0.01 SUI creation fee
)
```

### Step 3: Agent Requests Authorization

The agent calls `authorize_action` which runs 10 validation checks atomically. All checks execute before any state mutation.

```
 1. Mandate not revoked
 2. Mandate not expired
 3. Agent address matches transaction sender
 4. Target protocol in whitelist
 5. Coin type in whitelist (empty whitelist = all allowed)
 6. Action type in whitelist (empty whitelist = all allowed)
 7. Amount > 0
 8. Amount <= spend_cap
 9. spent_this_epoch + amount <= daily_limit (auto-resets each epoch)
10. Agent reputation score >= min_agent_score (if set on mandate)
```

If all checks pass, a hot-potato `AuthToken` is issued.

### Step 4: Protocol Consumes the Token

The AuthToken has **zero Move abilities**. It cannot be stored, copied or dropped. The Move compiler enforces this at compile time. The protocol must consume the token in the same Programmable Transaction Block by calling `consume_auth_token`, which destructures it and verifies the protocol address and amount match.

```move
public struct AuthToken {       // no abilities declaration
    mandate_id: ID,
    agent: address,
    protocol: address,
    coin_type: TypeName,
    amount: u64,
    action_type: u8,
    authorized_at_epoch: u64,
    agent_score_at_auth: u64,   // score snapshot at authorization time
}
```

### Step 5: Receipt Frozen On-Chain

After the action executes an `ActionReceipt` is created and immediately frozen via `transfer::freeze_object`. It can never be modified or deleted. It records the agent, protocol, amount, success/failure, chain depth and the agent's reputation score at the time of action.

```
authorize_action  -->  protocol executes  -->  create_receipt  -->  freeze_object
    (hot potato)         (real action)         (record result)     (permanent)
```

This entire sequence happens in a single Programmable Transaction Block.

## Reputation Scoring

Every agent accumulates an on-chain reputation score from 0 to 1000. The score is computed using integer-only math (no floats, no oracles) after the agent completes 10+ actions. Recomputation respects a 10-epoch cooldown to prevent spam updates.

```
Component           Max Weight    Calculation
-----------         ----------    -----------
Accuracy                  400     (successful_actions / total_actions) * 400
Volume                    200     min((total_volume / 1T MIST) * 200, 200)
Account Age               200     min((days_active / 180) * 200, 200)
Streak                     50     min((consecutive_successes / 100) * 50, 50)
Protocol Diversity         50     min((unique_protocols / 5) * 50, 50)
Revocation Penalty       -200     min(revocations * 50, 200)
                        -----
Maximum Score            1000
```

Protocols can optionally require a minimum score on any mandate via `min_agent_score`. This creates a natural adoption curve:

```
Months 0-3      Passports created silently. Nobody queries scores yet.
Months 3-6      Early protocols read scores for analytics. No gating.
Months 6-12     Clear score distribution emerges. Protocols start gating.
Months 12+      New agents must build reputation through MoveGate.
Month 18+       MoveGate is permanent infrastructure.
```

### Verification Tiers

Admins can assign verification tiers to agents via `AdminCap`:

| Tier | Name | Meaning |
|---|---|---|
| 0 | None | Default. No verification. |
| 1 | Basic | Identity confirmed. |
| 2 | Audited | Code reviewed by third party. |
| 3 | Certified | Full audit complete. Highest trust. |

## Delegation Chains

Mandates support hierarchical delegation up to 5 levels deep. Child mandates inherit constraints from the parent and can only narrow permissions.

```
User (Owner)
  |
  +-- Mandate (depth 0, cap: 10 SUI, daily: 100 SUI, protocols: [A, B, C])
        |
        +-- Child (depth 1, cap: 5 SUI, daily: 50 SUI, protocols: [A, B])
              |
              +-- Grandchild (depth 2, cap: 2 SUI, daily: 20 SUI, protocols: [A])
```

On-chain enforcement:

- Child `spend_cap` must be <= parent `spend_cap`
- Child `daily_limit` must be <= parent `daily_limit`
- Child `expires_at` must be <= parent `expires_at`
- Child protocols must be a subset of parent protocols
- Maximum delegation depth: 5

## Protocol Integration

For a DeFi protocol to integrate MoveGate, the protocol function accepts an `AuthToken` parameter and consumes it:

```move
public fun deposit(
    amount: Coin<USDC>,
    auth: AuthToken,                // from MoveGate
    pool: &mut LendingPool,
    ctx: &mut TxContext
) {
    // Consume and verify the token came from a valid mandate
    movegate::mandate::consume_auth_token(auth, PROTOCOL_ADDRESS, coin::value(&amount));

    // Optional: query agent passport for risk analytics
    // let score = movegate::passport::reputation_score(passport);

    // Proceed with deposit logic
}
```

## Fee Model

| Fee Type | Default | Mechanism |
|---|---|---|
| Passport Creation | **Free** | Zero friction. Critical for adoption. |
| Mandate Creation | 0.01 SUI (10M MIST) | Flat fee. Anti-spam + revenue. |
| Authorization | 2 bps (0.02%) | Percentage of action amount. u128 intermediary prevents overflow. |

Fee parameters are configurable by `AdminCap`. Authorization fee BPS is capped at 500 (5%). All fee math uses multiply-before-divide with u128 intermediary to prevent precision loss and overflow.

## Use Cases

### DeFi Yield Optimizer

A yield agent continuously rebalances funds across lending protocols like NAVI and Scallop to maximize APY. The user grants a 30-day mandate scoped to deposit and withdraw actions on two protocols with a $5K daily limit. The agent builds a reputation score over hundreds of successful rebalances. After 3 months the agent reaches score 850 and qualifies for higher-value mandates from institutional users who set `min_agent_score: 700`.

```
Protocols:    [NAVI, Scallop]
Spend Cap:    5,000,000,000 MIST (5 SUI per tx)
Daily Limit:  50,000,000,000 MIST (50 SUI per epoch)
Actions:      [deposit, withdraw]
Expiry:       30 days
Min Score:    700
```

### Automated Trading Bot

A trading bot executes swaps on Cetus based on market signals. The developer deploys the bot and it starts with a passport score of 0. Over weeks of successful trades the score climbs. Protocol partners can see the agent's full history: 2,400 trades, 99.8% success rate, zero revocations. That track record is on-chain and impossible to fabricate.

```
Protocols:    [Cetus]
Spend Cap:    500,000,000 MIST (0.5 SUI per tx)
Daily Limit:  2,000,000,000 MIST (2 SUI per epoch)
Actions:      [swap]
Expiry:       7 days (renewable)
Min Score:    None (builds over time)
```

### DAO Treasury Executor

A DAO votes to authorize an agent to execute approved proposals against a governance contract. The mandate is scoped to fixed amounts with a certified verification tier required. The agent's passport shows it has executed 500+ governance actions across 3 DAOs with zero revocations. The frozen receipt trail provides the DAO with an immutable audit log for compliance.

```
Protocols:    [Governance Contract]
Spend Cap:    Fixed per proposal
Daily Limit:  Proposal-specific
Actions:      [execute_proposal]
Expiry:       Per proposal cycle
Min Score:    900 + Certified tier (tier 3)
```

### Liquidation Bot

A lending protocol needs liquidation bots operating 24/7. The protocol sets a minimum passport score of 600 for any agent performing liquidations. New bots must prove reliability on smaller liquidations before the protocol grants access to high-value positions. The score acts as a permissionless gatekeeping mechanism that the protocol does not need to manage manually.

```
Protocols:    [Lending Protocol internal]
Spend Cap:    Protocol-defined
Daily Limit:  Unlimited (high throughput required)
Actions:      [liquidate]
Expiry:       Ongoing
Min Score:    600 (protocol enforced)
```

### Portfolio Rebalancer

A non-technical user finds a rebalancer agent on the MoveGate marketplace. Before granting permission the user sees the agent's passport: score 920, verified tier 2, 8,000 successful actions, 12 unique protocols, zero revocations in 6 months. The user grants a 90-day mandate via zkLogin (Google account, no wallet needed) with a $500 daily limit and instant one-click revocation available at any time.

```
Protocols:    [NAVI, Cetus, Scallop, Bluefin]
Spend Cap:    1,000,000,000 MIST (1 SUI per tx)
Daily Limit:  5,000,000,000 MIST (5 SUI per epoch)
Actions:      [deposit, withdraw, swap]
Expiry:       90 days
Min Score:    800
```

### Cross-Protocol Arbitrage

A high-frequency arbitrage agent operates across multiple DEXs with millisecond timing. Higher passport scores unlock tighter spread tolerances from protocols because the agent has a proven track record. The agent delegates sub-mandates to specialized execution agents using the delegation chain (up to 5 levels deep) where each child mandate narrows the parent's permissions.

```
Protocols:    [Cetus, Turbos, DeepBook]
Spend Cap:    10,000,000,000 MIST (10 SUI per tx)
Daily Limit:  100,000,000,000 MIST (100 SUI per epoch)
Actions:      [swap]
Expiry:       7 days
Min Score:    850 (earned through volume)
Delegation:   Parent -> 3 child agents (depth 1)
```

### Subscription Payment

A user authorizes recurring monthly payments to a service provider. The mandate is scoped to a single payee address with a fixed monthly amount. Reputation score is not required for fixed-amount subscriptions. The frozen receipt trail provides payment proof for both parties.

```
Protocols:    [Service Provider Address]
Spend Cap:    10,000,000,000 MIST (10 SUI, monthly fee)
Daily Limit:  10,000,000,000 MIST
Actions:      [transfer]
Expiry:       365 days
Min Score:    None
```

### Gaming Guild Agent (EVE Frontier)

A gaming guild deploys an agent to manage in-game assets across guild members. New game agents start with score 0, which is acceptable for gaming use cases. As the agent manages more assets and builds history, it earns reputation that carries over if the guild expands to DeFi operations. The passport is portable across all Sui protocols.

```
Protocols:    [EVE Frontier Contracts]
Spend Cap:    Game-specific limits
Daily Limit:  Guild-defined
Actions:      [game_action]
Expiry:       Season-based
Min Score:    None (new agents welcome)
```

## Testnet Deployment

```
Network:    Sui Testnet
Package ID: 0xec91e604714e263ad43723d43470f236607bd0b13f64731aad36b00a61cf884a
Tx Digest:  AWJUKXSDEVvUrSBmSDhrncnRyBwsShQcQR6UJi16Ge5Q
Deployer:   0xaca7964ff16c481ae3c2f43580accd730574d87badc5557719af58abe50b47e3
```

Objects created on publish:

| Object | ID | Type |
|---|---|---|
| `AgentRegistry` | `0xb2fadc7ccf9c7b578ba3b1adb8ebfd73191563e536b6b2cc18aa14dac6c7ba46` | Shared |
| `MandateRegistry` | `0x26a66d91fef324b833d07d134e5ab6e796e0dfd77f670c27da099479d939b0d3` | Shared |
| `FeeConfig` | `0x5c92c420f4b3801eb4126fcab6cb4b98212b31f591b4b3d0a025b4e4957120f3` | Shared |
| `ProtocolTreasury` | `0xf0714bd816e595cacfc9e5921d1754cca0205f6b65867eab6183d0b0a98fc82c` | Shared |
| `AdminCap` | `0x37464b867d7d5fa77380ca0ba6ce30bb38680dff0cc69373363a173c10533dd6` | Owned by deployer |
| `UpgradeCap` | `0xda32476b5cb8819c803da3088106d216739f4c1b4629411e0a069ffc180640bd` | Owned by deployer |

## Project Structure

```
movegate/
  Move.toml                       Sui 1.67.2, edition 2024.beta
  sources/
    errors.move                   35 error codes across 7 categories
    events.move                   11 event types with package-private emitters
    treasury.move                 AdminCap + FeeConfig + ProtocolTreasury
    passport.move                 AgentPassport + AgentRegistry + reputation engine
    mandate.move                  Mandate + AuthToken + 10-check authorization
    receipt.move                  ActionReceipt (frozen immutable objects)
  tests/
    coverage_tests.move           Edge case coverage and accessor tests
    mandate_tests.move            Mandate creation + authorization edge cases
    passport_tests.move           Passport lifecycle + reputation formula tests
    delegation_tests.move         Delegation chain validation tests
    integration_tests.move        End-to-end scenario tests
    receipt_tests.move            Receipt creation + freeze tests
    treasury_tests.move           Fee collection + admin function tests
```

## Build and Test

Requires [Sui CLI](https://docs.sui.io/build/install) v1.67.2 or later.

```bash
# Build (zero warnings)
sui move build

# Run all tests
sui move test

# Coverage analysis
sui move test --coverage
sui move coverage summary --test
```

**83 tests** across 7 test modules. **96.66% line coverage.** Zero warnings. Zero TODO/FIXME/HACK in production code.

Test categories cover all 55+ edge cases from the specification:

| Category | Count | What Is Tested |
|---|---|---|
| A: Mandate Creation | 15 | Invalid expiry, zero spend cap, empty protocols, fee validation |
| B: Authorization | 16 | Wrong agent, expired, revoked, spend cap, daily limit, coin/action type filtering |
| C: Revocation | 4 | Non-owner revoke, double revoke, cascade behavior |
| D: Delegation | 5 | Parent cap exceeded, protocol subset, child outlives parent, depth limit |
| E: Treasury | 3 | Zero balance withdrawal, fee ceiling, non-admin access |
| G: Passport | 10 | Auto-creation, score threshold, revocation penalty, streak reset, verification |
| Integration | 12+ | Full transaction flows, multi-action scenarios, epoch resets |

## Security Model

**Checks before effects.** All 10 authorization checks execute before any state mutation. No partial state updates on failure. No TOCTOU vulnerabilities.

**Hot-potato enforcement.** The Move type system guarantees at compile time that AuthTokens cannot escape the transaction in which they are issued. This is not a runtime check. It is a structural impossibility.

**Immutable audit trail.** Frozen receipts provide non-repudiable proof of every action. Neither the agent nor the user nor the protocol can alter historical records. Retroactive fabrication is cryptographically impossible.

**Integer-only math.** All fee calculations use u128 intermediary values. No floating point. No external oracles. Score computation uses min/max capping at every step to prevent overflow.

**Package-private visibility.** Event emitters and internal state mutators are `public(package)`. External contracts cannot spoof events or bypass the authorization gate. Passport updates flow exclusively through `record_action` which is only callable within the package.

**No passport spoofing.** `ensure_passport` is `public(package)`. External contracts cannot create fake passports. Passport data is only updated through authorized action flows.

**Ownership verification.** Every mutation verifies `sender == expected_owner`. AdminCap is created once in `init()` and transferred to the deployer. No public function exposes AdminCap creation.

## Move Vulnerability Checklist

| Category | Check | Implementation |
|---|---|---|
| Ownership | Every mutation verifies sender | `mandate.owner == sender` for revocation |
| Ownership | AdminCap never exposed | Created once in `init()`, holder-only transfer |
| Passport | No external passport creation | `ensure_passport` is `public(package)` |
| Passport | No duplicate passports | `Table::contains` check before `Table::add` |
| Passport | Data only updated through auth flow | `record_action` is `public(package)` |
| Arithmetic | Multiply before divide | `(amount * fee_bps) / 10_000` |
| Arithmetic | u128 intermediary for fees | Prevents u64 overflow on large amounts |
| Arithmetic | Score cannot overflow | Each component capped via `min()` before summing |
| Hot Potato | AuthToken zero abilities | `public struct AuthToken { }` with no `has` clause |
| Hot Potato | Consumed by full destructuring | `let AuthToken { ... } = token` |
| Hot Potato | Score snapshot at auth time | `agent_score_at_auth` copied before issuing |
| Lifecycle | Receipt frozen immediately | `transfer::freeze_object` in same PTB |
| Lifecycle | Passport never deleted | No delete function exists |
| Ordering | All asserts before state changes | Prevents TOCTOU and partial mutations |

## All Constants

| Constant | Value | Purpose |
|---|---|---|
| `MIN_SPEND_CAP` | 1,000 MIST | Anti-spam minimum |
| `MAX_PROTOCOLS` | 20 | Caps whitelist length to prevent DoS |
| `MAX_DELEGATION_DEPTH` | 5 | Prevents infinite chain loops |
| `MANDATE_CREATION_FEE` | 10,000,000 MIST | 0.01 SUI |
| `PASSPORT_CREATION_FEE` | 0 MIST | Free. Zero friction. |
| `AUTH_FEE_BPS` | 2 | 0.02% micro-fee per action |
| `MAX_FEE_BPS` | 500 | 5% ceiling |
| `REPUTATION_MAX` | 1,000 | Score ceiling |
| `REVOKE_PENALTY` | 50 per revocation | Max 200 total penalty |
| `SCORE_COOLDOWN` | 10 epochs | Prevents spam recomputation |
| `VOLUME_THRESHOLD` | 1,000,000,000,000 MIST | ~$1M volume for max volume score |
| `MIN_ACTIONS_FOR_SCORE` | 10 | Score not computed until 10 actions |
| `AGE_THRESHOLD_DAYS` | 180 | 6 months for max age score |
| `STREAK_THRESHOLD` | 100 | 100 consecutive successes for max streak |
| `DIVERSITY_THRESHOLD` | 5 | 5 unique protocols for max diversity |
| `MAX_TOP_PROTOCOLS` | 10 | Maximum protocols tracked in passport history |

## Error Codes

| Range | Category | Examples |
|---|---|---|
| 1-9 | Mandate Creation | Invalid expiry, spend cap, agent address, protocol list |
| 10-19 | Authorization | Wrong agent, expired, revoked, protocol/coin/action not allowed |
| 20-21 | Revocation | Not owner, already revoked |
| 22-26 | Delegation | Exceeds parent cap/daily, protocol not in parent, child outlives parent |
| 27-30 | Treasury | Zero balance, fee too high, not admin |
| 31 | Upgrade | Reserved |
| 32-35 | Passport | Already exists, not found, cooldown active, amount mismatch |

## Events

All events have `copy, drop` abilities. All emitters are `public(package)` to prevent external spoofing.

| Event | Emitted When |
|---|---|
| `PassportCreated` | New agent passport auto-created on first action |
| `ScoreUpdated` | Reputation score recomputed with old and new values |
| `VerificationTierChanged` | Admin changes agent verification tier |
| `MandateCreated` | New mandate created with full parameters |
| `MandateRevoked` | Owner revokes a mandate with reason code |
| `MandateDelegated` | Child mandate delegated from parent with depth |
| `ActionAuthorized` | AuthToken issued after 10 checks pass |
| `ReceiptCreated` | Action receipt frozen on-chain with success/failure |
| `FeeCollected` | Fee deposited into protocol treasury |
| `TreasuryWithdrawal` | Admin withdraws accumulated fees |
| `FeeConfigUpdated` | Admin changes fee BPS |

## What Makes This Hard to Replicate

| Advantage | Why It Compounds |
|---|---|
| Agent behavior data | 12 months of on-chain receipts from thousands of agents cannot be retroactively manufactured by a fork |
| Reputation scores | Computed from real verified actions. A fork starts every agent at zero. |
| Protocol integrations | Once NAVI, Cetus or Scallop integrate MoveGate into their core contracts, switching cost is high |
| Hot-potato pattern | Authorization bypass is structurally impossible at the type-system level |
| Immutable receipts | Frozen objects on Sui cannot be modified by anyone, including the protocol itself |
| First-mover data | The window closes once 5 protocols integrate. Late entrants start with zero data. |

## SDK

The TypeScript SDK is published on npm and provides full protocol coverage: queries, transaction builders, event parsing and the `$extend` client pattern for Sui v2.

```bash
npm install @movegate/sdk @mysten/sui
```

See [@movegate/sdk on GitHub](https://github.com/hamzzaaamalik/movegate-sdk) or [npm](https://www.npmjs.com/package/@movegate/sdk).

## Roadmap

| Phase | Status | Deliverable |
|---|---|---|
| Layer 1 | Complete | Smart contracts. 6 modules. 83 tests. 96.66% coverage. |
| Layer 2 | Complete | TypeScript SDK ([`@movegate/sdk`](https://github.com/hamzzaaamalik/movegate-sdk)). Queries, tx builders, 37 tests. |
| Layer 3 | Next | Three frontend portals: Protocol Partner Dashboard, Agent Developer Console, End User Mandate Manager |
| Security Audit | Planned | MoveBit audit submission. Full vulnerability checklist pre-verified. |
| Mainnet | Planned | Production deployment with AdminCap in multisig. |

## License

MIT
