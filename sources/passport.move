/// Agent identity registry — the core identity layer for MoveGate.
/// AgentPassport is a shared object auto-created on first action. Never deleted.
/// Dependencies: errors, events (NO dependency on mandate — intentional)
module movegate::passport;

use sui::table::{Self, Table};
use sui::clock::Clock;
use movegate::errors;
use movegate::events;

// ═══════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════

/// Maximum reputation score
const REPUTATION_MAX: u64 = 1_000;

/// Score not computed until this many actions completed
const MIN_ACTIONS_FOR_SCORE: u64 = 10;

/// Revocation penalty per revocation (capped at MAX_REVOKE_PENALTY)
const REVOKE_PENALTY_PER: u64 = 50;

/// Maximum total revocation penalty
const MAX_REVOKE_PENALTY: u64 = 200;

/// Volume threshold for max volume score (1T MIST = ~$1M)
const VOLUME_THRESHOLD: u64 = 1_000_000_000_000;

/// Days active threshold for max age score
const AGE_THRESHOLD_DAYS: u64 = 180;

/// Consecutive successes for max streak bonus
const STREAK_THRESHOLD: u64 = 100;

/// Unique protocols for max diversity bonus
const DIVERSITY_THRESHOLD: u64 = 5;

/// Score cooldown in epochs
const SCORE_COOLDOWN_EPOCHS: u64 = 10;

/// Max top protocols tracked
const MAX_TOP_PROTOCOLS: u64 = 10;

/// Milliseconds per day
const MS_PER_DAY: u64 = 86_400_000;

// ═══════════════════════════════════════════════════════════════════
// Structs
// ═══════════════════════════════════════════════════════════════════

/// Permanent on-chain identity for every agent. Shared object.
/// Auto-created on first action. Never deleted. Immutable address binding.
public struct AgentPassport has key {
    id: UID,
    /// The agent address this passport belongs to
    agent: address,
    // ── Registration ──────────────────────────────────────────
    registered_at_ms: u64,
    registered_at_epoch: u64,
    // ── Lifetime Stats ────────────────────────────────────────
    total_actions: u64,
    successful_actions: u64,
    failed_actions: u64,
    total_volume_mist: u64,
    unique_users: u64,
    unique_protocols: u64,
    // ── Trust Signals ─────────────────────────────────────────
    revocations_received: u64,
    consecutive_successes: u64,
    last_action_epoch: u64,
    active_mandate_count: u64,
    // ── Reputation Score ──────────────────────────────────────
    reputation_score: u64,
    last_score_update_epoch: u64,
    // ── Verification Tier ─────────────────────────────────────
    verification_tier: u8,
    verified: bool,
    verified_at_ms: Option<u64>,
    // ── Protocol History (top 10 by volume) ───────────────────
    top_protocols: vector<address>,
    // ── Internal tracking for unique counts ───────────────────
    known_users: Table<address, bool>,
    known_protocols: Table<address, bool>,
}

/// Global registry of all agent passports. Shared object.
public struct AgentRegistry has key {
    id: UID,
    /// Maps agent_address -> passport_object_id
    passport_index: Table<address, ID>,
    total_registered: u64,
    total_actions_all_time: u64,
    total_volume_all_time: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Init
// ═══════════════════════════════════════════════════════════════════

fun init(ctx: &mut TxContext) {
    transfer::share_object(AgentRegistry {
        id: object::new(ctx),
        passport_index: table::new(ctx),
        total_registered: 0,
        total_actions_all_time: 0,
        total_volume_all_time: 0,
    });
}

// ═══════════════════════════════════════════════════════════════════
// Package-Private Functions — called only from mandate.move
// ═══════════════════════════════════════════════════════════════════

/// Auto-create a passport for an agent if one does not exist.
/// Must be called in a prior transaction before create_mandate or authorize_action. FREE — no fee.
public(package) fun ensure_passport(
    registry: &mut AgentRegistry,
    agent: address,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    if (table::contains(&registry.passport_index, agent)) return;

    let passport = AgentPassport {
        id: object::new(ctx),
        agent,
        registered_at_ms: clock.timestamp_ms(),
        registered_at_epoch: ctx.epoch(),
        total_actions: 0,
        successful_actions: 0,
        failed_actions: 0,
        total_volume_mist: 0,
        unique_users: 0,
        unique_protocols: 0,
        revocations_received: 0,
        consecutive_successes: 0,
        last_action_epoch: 0,
        active_mandate_count: 0,
        reputation_score: 0,
        last_score_update_epoch: 0,
        verification_tier: 0,
        verified: false,
        verified_at_ms: option::none(),
        top_protocols: vector::empty(),
        known_users: table::new(ctx),
        known_protocols: table::new(ctx),
    };

    let passport_id = object::id(&passport);
    events::emit_passport_created(passport_id, agent, ctx.epoch(), clock.timestamp_ms());

    table::add(&mut registry.passport_index, agent, passport_id);
    registry.total_registered = registry.total_registered + 1;

    transfer::share_object(passport);
}

/// Record a successful or failed action on the agent's passport.
/// Updates stats, streak, unique tracking, and triggers score recomputation.
public(package) fun record_action(
    passport: &mut AgentPassport,
    registry: &mut AgentRegistry,
    owner: address,
    protocol: address,
    amount: u64,
    success: bool,
    clock: &Clock,
    ctx: &TxContext,
) {
    // Update lifetime stats
    passport.total_actions = passport.total_actions + 1;
    passport.total_volume_mist = passport.total_volume_mist + amount;
    passport.last_action_epoch = ctx.epoch();

    if (success) {
        passport.successful_actions = passport.successful_actions + 1;
        passport.consecutive_successes = passport.consecutive_successes + 1;
    } else {
        passport.failed_actions = passport.failed_actions + 1;
        passport.consecutive_successes = 0; // Reset streak on failure
    };

    // Track unique users
    if (!table::contains(&passport.known_users, owner)) {
        table::add(&mut passport.known_users, owner, true);
        passport.unique_users = passport.unique_users + 1;
    };

    // Track unique protocols
    if (!table::contains(&passport.known_protocols, protocol)) {
        table::add(&mut passport.known_protocols, protocol, true);
        passport.unique_protocols = passport.unique_protocols + 1;
        // Add to top_protocols if space available
        if (vector::length(&passport.top_protocols) < MAX_TOP_PROTOCOLS) {
            vector::push_back(&mut passport.top_protocols, protocol);
        };
    };

    // Update global registry stats
    registry.total_actions_all_time = registry.total_actions_all_time + 1;
    registry.total_volume_all_time = registry.total_volume_all_time + amount;

    // Recompute reputation score
    maybe_update_score(passport, clock, ctx);
}

/// Record a revocation against this agent's passport.
public(package) fun record_revocation(
    passport: &mut AgentPassport,
    clock: &Clock,
    ctx: &TxContext,
) {
    passport.revocations_received = passport.revocations_received + 1;
    if (passport.active_mandate_count > 0) {
        passport.active_mandate_count = passport.active_mandate_count - 1;
    };
    maybe_update_score(passport, clock, ctx);
}

/// Increment active mandate count when a new mandate is created for this agent.
public(package) fun increment_mandate_count(passport: &mut AgentPassport) {
    passport.active_mandate_count = passport.active_mandate_count + 1;
}

/// Decrement active mandate count when a mandate expires or is consumed.
public(package) fun decrement_mandate_count(passport: &mut AgentPassport) {
    if (passport.active_mandate_count > 0) {
        passport.active_mandate_count = passport.active_mandate_count - 1;
    };
}

// ═══════════════════════════════════════════════════════════════════
// Reputation Score Computation — Internal
// ═══════════════════════════════════════════════════════════════════

/// Recompute score if enough actions and cooldown elapsed.
fun maybe_update_score(
    passport: &mut AgentPassport,
    clock: &Clock,
    ctx: &TxContext,
) {
    if (passport.total_actions < MIN_ACTIONS_FOR_SCORE) return;

    // Respect cooldown — don't recompute too frequently
    if (ctx.epoch() < passport.last_score_update_epoch + SCORE_COOLDOWN_EPOCHS
        && passport.reputation_score > 0) return;

    let old_score = passport.reputation_score;
    let new_score = compute_score(passport, clock);

    passport.reputation_score = new_score;
    passport.last_score_update_epoch = ctx.epoch();

    if (old_score != new_score) {
        events::emit_score_updated(passport.agent, old_score, new_score, ctx.epoch());
    };
}

/// Pure computation of reputation score. Integer math only.
/// accuracy(400) + volume(200) + age(200) + streak(50) + diversity(50) - penalty(max 200)
fun compute_score(passport: &AgentPassport, clock: &Clock): u64 {
    let total = passport.total_actions;
    if (total == 0) return 0;

    // Accuracy: (successful / total) * 400
    let accuracy = (passport.successful_actions * 400) / total;

    // Volume: min((volume / VOLUME_THRESHOLD) * 200, 200)
    let volume = if (passport.total_volume_mist >= VOLUME_THRESHOLD) {
        200
    } else {
        (passport.total_volume_mist * 200) / VOLUME_THRESHOLD
    };

    // Age: min((days_active / 180) * 200, 200)
    let now_ms = clock.timestamp_ms();
    let age_ms = if (now_ms > passport.registered_at_ms) {
        now_ms - passport.registered_at_ms
    } else {
        0
    };
    let days_active = age_ms / MS_PER_DAY;
    let age = if (days_active >= AGE_THRESHOLD_DAYS) {
        200
    } else {
        (days_active * 200) / AGE_THRESHOLD_DAYS
    };

    // Streak: min((consecutive / 100) * 50, 50)
    let streak = if (passport.consecutive_successes >= STREAK_THRESHOLD) {
        50
    } else {
        (passport.consecutive_successes * 50) / STREAK_THRESHOLD
    };

    // Diversity: min((unique_protocols / 5) * 50, 50)
    let diversity = if (passport.unique_protocols >= DIVERSITY_THRESHOLD) {
        50
    } else {
        (passport.unique_protocols * 50) / DIVERSITY_THRESHOLD
    };

    // Penalty: min(revocations * 50, 200)
    let penalty = passport.revocations_received * REVOKE_PENALTY_PER;
    let penalty = if (penalty > MAX_REVOKE_PENALTY) { MAX_REVOKE_PENALTY } else { penalty };

    // Final: max(0, sum - penalty), capped at REPUTATION_MAX
    let sum = accuracy + volume + age + streak + diversity;
    let score = if (sum > penalty) { sum - penalty } else { 0 };
    if (score > REPUTATION_MAX) { REPUTATION_MAX } else { score }
}

// ═══════════════════════════════════════════════════════════════════
// Admin Functions
// ═══════════════════════════════════════════════════════════════════

/// Set verification tier for an agent. Admin only (via treasury AdminCap).
public fun set_verification_tier(
    _admin: &movegate::treasury::AdminCap,
    passport: &mut AgentPassport,
    tier: u8,
    clock: &Clock,
) {
    let old_tier = passport.verification_tier;
    passport.verification_tier = tier;
    passport.verified = tier > 0;
    if (tier > 0) {
        passport.verified_at_ms = option::some(clock.timestamp_ms());
    } else {
        passport.verified_at_ms = option::none();
    };
    events::emit_verification_tier_changed(passport.agent, old_tier, tier);
}

// ═══════════════════════════════════════════════════════════════════
// Public Entry Points — callable by external users and protocols
// ═══════════════════════════════════════════════════════════════════

/// Register the transaction sender as an agent. Creates a passport if one does not exist.
/// Free. Idempotent. Safe to call multiple times.
public fun register_agent(
    registry: &mut AgentRegistry,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    ensure_passport(registry, ctx.sender(), clock, ctx);
}

// ═══════════════════════════════════════════════════════════════════
// Public Read Accessors — callable by any protocol
// ═══════════════════════════════════════════════════════════════════

public fun has_passport(registry: &AgentRegistry, agent: address): bool {
    table::contains(&registry.passport_index, agent)
}

public fun get_passport_id(registry: &AgentRegistry, agent: address): ID {
    assert!(table::contains(&registry.passport_index, agent), errors::passport_not_found());
    *table::borrow(&registry.passport_index, agent)
}

public fun agent(passport: &AgentPassport): address { passport.agent }
public fun total_actions(passport: &AgentPassport): u64 { passport.total_actions }
public fun successful_actions(passport: &AgentPassport): u64 { passport.successful_actions }
public fun failed_actions(passport: &AgentPassport): u64 { passport.failed_actions }
public fun total_volume(passport: &AgentPassport): u64 { passport.total_volume_mist }
public fun reputation_score(passport: &AgentPassport): u64 { passport.reputation_score }
public fun verification_tier(passport: &AgentPassport): u8 { passport.verification_tier }
public fun verified(passport: &AgentPassport): bool { passport.verified }
public fun unique_users(passport: &AgentPassport): u64 { passport.unique_users }
public fun unique_protocols(passport: &AgentPassport): u64 { passport.unique_protocols }
public fun revocations_received(passport: &AgentPassport): u64 { passport.revocations_received }
public fun consecutive_successes(passport: &AgentPassport): u64 { passport.consecutive_successes }
public fun active_mandate_count(passport: &AgentPassport): u64 { passport.active_mandate_count }
public fun registered_at_ms(passport: &AgentPassport): u64 { passport.registered_at_ms }
public fun last_action_epoch(passport: &AgentPassport): u64 { passport.last_action_epoch }
public fun top_protocols(passport: &AgentPassport): &vector<address> { &passport.top_protocols }

public fun registry_total_registered(registry: &AgentRegistry): u64 { registry.total_registered }
public fun registry_total_actions(registry: &AgentRegistry): u64 { registry.total_actions_all_time }
public fun registry_total_volume(registry: &AgentRegistry): u64 { registry.total_volume_all_time }

// ═══════════════════════════════════════════════════════════════════
// Test Helpers
// ═══════════════════════════════════════════════════════════════════

// Error constants mirrored from errors.move for #[expected_failure] annotations
#[test_only] const EPassportNotFound: u64 = 33;

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun min_actions_for_score(): u64 { MIN_ACTIONS_FOR_SCORE }

#[test_only]
public fun reputation_max(): u64 { REPUTATION_MAX }

#[test_only]
public fun revoke_penalty_per(): u64 { REVOKE_PENALTY_PER }

#[test_only]
public fun max_revoke_penalty(): u64 { MAX_REVOKE_PENALTY }
