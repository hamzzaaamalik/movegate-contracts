/// Permission objects and authorization via hot potato AuthToken.
/// The core authorization layer for MoveGate.
/// Dependencies: errors, events, treasury, passport
module movegate::mandate;

use sui::coin::Coin;
use sui::sui::SUI;
use sui::table::{Self, Table};
use sui::clock::Clock;
use std::type_name::{Self, TypeName};
use movegate::errors;
use movegate::events;
use movegate::treasury::{Self, FeeConfig, ProtocolTreasury};
use movegate::passport::{Self, AgentPassport, AgentRegistry};

// ═══════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════

/// Anti-spam minimum spend cap
const MIN_SPEND_CAP: u64 = 1_000;

/// Maximum protocols in whitelist — prevents DoS via unbounded iteration
const MAX_PROTOCOLS: u64 = 20;

/// Maximum delegation depth — prevents infinite chain loops
const MAX_DELEGATION_DEPTH: u8 = 5;

// ═══════════════════════════════════════════════════════════════════
// Structs
// ═══════════════════════════════════════════════════════════════════

/// Permission object granting an agent bounded access to act on behalf of the owner.
public struct Mandate has key, store {
    id: UID,
    owner: address,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    spent_this_epoch: u64,
    last_reset_epoch: u64,
    allowed_protocols: vector<address>,
    allowed_coin_types: vector<TypeName>,
    allowed_actions: vector<u8>,
    created_at_ms: u64,
    expires_at_ms: u64,
    revoked: bool,
    revoked_at_ms: Option<u64>,
    revoke_reason: Option<u8>,
    total_actions: u64,
    successful_actions: u64,
    total_volume: u64,
    parent_mandate_id: Option<ID>,
    max_delegation_depth: u8,
    current_depth: u8,
    min_agent_score: Option<u64>,
}

/// Hot potato authorization token. ZERO ABILITIES.
/// Must be consumed in the same programmable transaction block.
/// Cannot be stored, copied, or dropped — enforced by Move type system.
public struct AuthToken {
    mandate_id: ID,
    agent: address,
    protocol: address,
    coin_type: TypeName,
    amount: u64,
    action_type: u8,
    authorized_at_epoch: u64,
    agent_score_at_auth: u64,
}

/// Global registry tracking all mandates.
public struct MandateRegistry has key {
    id: UID,
    /// Maps mandate_id -> owner for fast lookup
    mandate_owners: Table<ID, address>,
    total_mandates_created: u64,
    total_mandates_active: u64,
    total_mandates_revoked: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Init
// ═══════════════════════════════════════════════════════════════════

fun init(ctx: &mut TxContext) {
    transfer::share_object(MandateRegistry {
        id: object::new(ctx),
        mandate_owners: table::new(ctx),
        total_mandates_created: 0,
        total_mandates_active: 0,
        total_mandates_revoked: 0,
    });
}

// ═══════════════════════════════════════════════════════════════════
// Create Mandate
// ═══════════════════════════════════════════════════════════════════

/// Create a new Mandate granting an agent bounded permissions.
/// Collects creation fee. Validates all parameters.
/// Caller must ensure the agent's passport exists before calling (via ensure_passport).
/// Increments the passport's active_mandate_count.
public fun create_mandate(
    registry: &mut MandateRegistry,
    _agent_registry: &mut AgentRegistry,
    passport: &mut AgentPassport,
    treasury: &mut ProtocolTreasury,
    fee_config: &FeeConfig,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    allowed_protocols: vector<address>,
    allowed_coin_types: vector<TypeName>,
    allowed_actions: vector<u8>,
    expires_at_ms: u64,
    min_agent_score: Option<u64>,
    payment: &mut Coin<SUI>,
    clock: &Clock,
    ctx: &mut TxContext,
): Mandate {
    let owner = ctx.sender();
    let now_ms = clock.timestamp_ms();

    // ── Validation: all asserts before any state change ──────
    assert!(agent != @0x0, errors::invalid_agent());
    assert!(spend_cap >= MIN_SPEND_CAP, errors::invalid_spend_cap());
    assert!(daily_limit >= spend_cap, errors::invalid_daily_limit());
    assert!(expires_at_ms > now_ms, errors::invalid_expiry());
    assert!(!vector::is_empty(&allowed_protocols), errors::empty_protocol_list());
    assert!(vector::length(&allowed_protocols) <= MAX_PROTOCOLS, errors::protocol_list_too_large());

    // Note: min_agent_score is stored on the mandate and enforced at authorize_action time,
    // not at creation time, since the agent's score may be 0 at this point.

    // ── Collect creation fee ─────────────────────────────────
    treasury::collect_creation_fee(treasury, fee_config, payment, ctx);

    // ── Track active mandate on passport ─────────────────────
    passport::increment_mandate_count(passport);

    // ── Create mandate ───────────────────────────────────────
    let mandate = Mandate {
        id: object::new(ctx),
        owner,
        agent,
        spend_cap,
        daily_limit,
        spent_this_epoch: 0,
        last_reset_epoch: ctx.epoch(),
        allowed_protocols,
        allowed_coin_types,
        allowed_actions,
        created_at_ms: now_ms,
        expires_at_ms,
        revoked: false,
        revoked_at_ms: option::none(),
        revoke_reason: option::none(),
        total_actions: 0,
        successful_actions: 0,
        total_volume: 0,
        parent_mandate_id: option::none(),
        max_delegation_depth: MAX_DELEGATION_DEPTH,
        current_depth: 0,
        min_agent_score,
    };

    let mandate_id = object::id(&mandate);

    // ── Update registry ──────────────────────────────────────
    table::add(&mut registry.mandate_owners, mandate_id, owner);
    registry.total_mandates_created = registry.total_mandates_created + 1;
    registry.total_mandates_active = registry.total_mandates_active + 1;

    events::emit_mandate_created(
        mandate_id,
        owner,
        agent,
        spend_cap,
        daily_limit,
        expires_at_ms,
        vector::length(&mandate.allowed_protocols),
    );

    mandate
}

// ═══════════════════════════════════════════════════════════════════
// Authorize Action — Issues Hot Potato AuthToken
// ═══════════════════════════════════════════════════════════════════

/// Run 10 authorization checks and issue a hot potato AuthToken.
/// Caller must ensure the agent's passport exists before calling (via ensure_passport).
/// All checks happen BEFORE any state mutation (TOCTOU prevention).
public fun authorize_action<CoinType>(
    mandate: &mut Mandate,
    passport: &mut AgentPassport,
    protocol: address,
    amount: u64,
    action_type: u8,
    clock: &Clock,
    ctx: &TxContext,
): AuthToken {
    let sender = ctx.sender();
    let now_ms = clock.timestamp_ms();
    let current_epoch = ctx.epoch();

    // ── 10 Authorization Checks (all before state mutation) ─────

    // Check 1: Mandate not revoked
    assert!(!mandate.revoked, errors::mandate_revoked());

    // Check 2: Mandate not expired
    assert!(now_ms < mandate.expires_at_ms, errors::expired_mandate());

    // Check 3: Agent address matches
    assert!(sender == mandate.agent, errors::wrong_agent());

    // Check 4: Protocol whitelisted
    assert!(vector_contains(&mandate.allowed_protocols, &protocol), errors::protocol_not_allowed());

    // Check 5: Coin type allowed (empty = all allowed)
    if (!vector::is_empty(&mandate.allowed_coin_types)) {
        let coin_type = type_name::with_original_ids<CoinType>();
        assert!(vector_contains_type(&mandate.allowed_coin_types, &coin_type), errors::coin_not_allowed());
    };

    // Check 6: Action type allowed (empty = all allowed)
    if (!vector::is_empty(&mandate.allowed_actions)) {
        assert!(vector_contains_u8(&mandate.allowed_actions, action_type), errors::action_not_allowed());
    };

    // Check 7: Amount > 0
    assert!(amount > 0, errors::zero_amount());

    // Check 8: Amount <= spend_cap
    assert!(amount <= mandate.spend_cap, errors::exceeds_spend_cap());

    // Check 9: Daily limit (reset epoch if needed, then check)
    if (mandate.last_reset_epoch < current_epoch) {
        mandate.spent_this_epoch = 0;
        mandate.last_reset_epoch = current_epoch;
    };
    assert!(
        mandate.spent_this_epoch + amount <= mandate.daily_limit,
        errors::daily_limit_exceeded(),
    );

    // Check 10: Min agent score (if set on mandate)
    if (option::is_some(&mandate.min_agent_score)) {
        let required = *option::borrow(&mandate.min_agent_score);
        assert!(passport::reputation_score(passport) >= required, errors::agent_score_too_low());
    };

    // ── State mutations (after all checks pass) ──────────────

    // Update spent tracking
    mandate.spent_this_epoch = mandate.spent_this_epoch + amount;
    mandate.total_actions = mandate.total_actions + 1;
    mandate.total_volume = mandate.total_volume + amount;

    // Snapshot score before issuing token
    let agent_score = passport::reputation_score(passport);

    let coin_type = type_name::with_original_ids<CoinType>();

    events::emit_action_authorized(
        object::id(mandate),
        sender,
        protocol,
        coin_type,
        amount,
        action_type,
        agent_score,
        current_epoch,
    );

    // ── Issue hot potato AuthToken ───────────────────────────
    AuthToken {
        mandate_id: object::id(mandate),
        agent: sender,
        protocol,
        coin_type,
        amount,
        action_type,
        authorized_at_epoch: current_epoch,
        agent_score_at_auth: agent_score,
    }
}

// ═══════════════════════════════════════════════════════════════════
// Consume AuthToken — Called by protocol after executing action
// ═══════════════════════════════════════════════════════════════════

/// Consume (destructure) the hot potato AuthToken.
/// Called by the protocol after executing the authorized action.
/// Verifies protocol address and amount match.
/// Returns the extracted fields for receipt creation.
public fun consume_auth_token(
    token: AuthToken,
    expected_protocol: address,
    expected_amount: u64,
): (ID, address, address, TypeName, u64, u8, u64, u64) {
    let AuthToken {
        mandate_id,
        agent,
        protocol,
        coin_type,
        amount,
        action_type,
        authorized_at_epoch,
        agent_score_at_auth,
    } = token;

    // Verify protocol and amount match what was authorized
    assert!(protocol == expected_protocol, errors::protocol_not_allowed());
    assert!(amount == expected_amount, errors::amount_mismatch());

    (mandate_id, agent, protocol, coin_type, amount, action_type, authorized_at_epoch, agent_score_at_auth)
}

// ═══════════════════════════════════════════════════════════════════
// Revocation
// ═══════════════════════════════════════════════════════════════════

/// Revoke a mandate. Only the owner can revoke.
public fun revoke_mandate(
    mandate: &mut Mandate,
    registry: &mut MandateRegistry,
    passport: &mut AgentPassport,
    revoke_reason: u8,
    clock: &Clock,
    ctx: &TxContext,
) {
    // All asserts before state change
    assert!(ctx.sender() == mandate.owner, errors::not_owner());
    assert!(!mandate.revoked, errors::already_revoked());

    // State mutations
    mandate.revoked = true;
    mandate.revoked_at_ms = option::some(clock.timestamp_ms());
    mandate.revoke_reason = option::some(revoke_reason);

    registry.total_mandates_active = registry.total_mandates_active - 1;
    registry.total_mandates_revoked = registry.total_mandates_revoked + 1;

    // Record revocation on passport
    passport::record_revocation(passport, clock, ctx);

    events::emit_mandate_revoked(
        object::id(mandate),
        mandate.owner,
        mandate.agent,
        revoke_reason,
        ctx.epoch(),
        clock.timestamp_ms(),
    );
}

// ═══════════════════════════════════════════════════════════════════
// Delegation
// ═══════════════════════════════════════════════════════════════════

/// Delegate a child mandate from a parent. Child limits must be <= parent limits.
public fun delegate_mandate(
    parent: &Mandate,
    registry: &mut MandateRegistry,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    allowed_protocols: vector<address>,
    expires_at_ms: u64,
    clock: &Clock,
    ctx: &mut TxContext,
): Mandate {
    let now_ms = clock.timestamp_ms();

    // Validation
    assert!(agent != @0x0, errors::invalid_agent());
    assert!(!vector::is_empty(&allowed_protocols), errors::empty_protocol_list());
    assert!(!parent.revoked, errors::mandate_revoked());
    assert!(now_ms < parent.expires_at_ms, errors::expired_mandate());
    assert!(parent.current_depth + 1 <= parent.max_delegation_depth, errors::max_depth_exceeded());
    assert!(spend_cap <= parent.spend_cap, errors::exceeds_parent_cap());
    assert!(daily_limit <= parent.daily_limit, errors::exceeds_parent_daily());
    assert!(expires_at_ms <= parent.expires_at_ms, errors::child_outlives_parent());
    assert!(expires_at_ms > now_ms, errors::invalid_expiry());

    // Verify all child protocols are in parent's whitelist
    let mut i = 0;
    let len = vector::length(&allowed_protocols);
    while (i < len) {
        let proto = *vector::borrow(&allowed_protocols, i);
        assert!(
            vector_contains(&parent.allowed_protocols, &proto),
            errors::protocol_not_in_parent(),
        );
        i = i + 1;
    };

    let child = Mandate {
        id: object::new(ctx),
        owner: ctx.sender(),
        agent,
        spend_cap,
        daily_limit,
        spent_this_epoch: 0,
        last_reset_epoch: ctx.epoch(),
        allowed_protocols,
        allowed_coin_types: parent.allowed_coin_types, // Inherit from parent
        allowed_actions: parent.allowed_actions, // Inherit from parent
        created_at_ms: now_ms,
        expires_at_ms,
        revoked: false,
        revoked_at_ms: option::none(),
        revoke_reason: option::none(),
        total_actions: 0,
        successful_actions: 0,
        total_volume: 0,
        parent_mandate_id: option::some(object::id(parent)),
        max_delegation_depth: parent.max_delegation_depth,
        current_depth: parent.current_depth + 1,
        min_agent_score: parent.min_agent_score,
    };

    let child_id = object::id(&child);
    table::add(&mut registry.mandate_owners, child_id, ctx.sender());
    registry.total_mandates_created = registry.total_mandates_created + 1;
    registry.total_mandates_active = registry.total_mandates_active + 1;

    events::emit_mandate_delegated(
        object::id(parent),
        child_id,
        agent,
        parent.current_depth + 1,
    );

    child
}

/// Mark a successful action on the mandate (called after receipt creation).
public(package) fun record_success(mandate: &mut Mandate) {
    mandate.successful_actions = mandate.successful_actions + 1;
}

// ═══════════════════════════════════════════════════════════════════
// Read Accessors
// ═══════════════════════════════════════════════════════════════════

public fun mandate_owner(mandate: &Mandate): address { mandate.owner }
public fun mandate_agent(mandate: &Mandate): address { mandate.agent }
public fun mandate_spend_cap(mandate: &Mandate): u64 { mandate.spend_cap }
public fun mandate_daily_limit(mandate: &Mandate): u64 { mandate.daily_limit }
public fun mandate_spent_this_epoch(mandate: &Mandate): u64 { mandate.spent_this_epoch }
public fun mandate_expires_at_ms(mandate: &Mandate): u64 { mandate.expires_at_ms }
public fun mandate_revoked(mandate: &Mandate): bool { mandate.revoked }
public fun mandate_total_actions(mandate: &Mandate): u64 { mandate.total_actions }
public fun mandate_total_volume(mandate: &Mandate): u64 { mandate.total_volume }
public fun mandate_current_depth(mandate: &Mandate): u8 { mandate.current_depth }
public fun mandate_parent_id(mandate: &Mandate): &Option<ID> { &mandate.parent_mandate_id }
public fun mandate_min_agent_score(mandate: &Mandate): &Option<u64> { &mandate.min_agent_score }
public fun mandate_allowed_protocols(mandate: &Mandate): &vector<address> { &mandate.allowed_protocols }

public fun auth_token_mandate_id(token: &AuthToken): ID { token.mandate_id }
public fun auth_token_agent(token: &AuthToken): address { token.agent }
public fun auth_token_protocol(token: &AuthToken): address { token.protocol }
public fun auth_token_amount(token: &AuthToken): u64 { token.amount }
public fun auth_token_action_type(token: &AuthToken): u8 { token.action_type }
public fun auth_token_score(token: &AuthToken): u64 { token.agent_score_at_auth }

public fun registry_total_created(registry: &MandateRegistry): u64 { registry.total_mandates_created }
public fun registry_total_active(registry: &MandateRegistry): u64 { registry.total_mandates_active }
public fun registry_total_revoked(registry: &MandateRegistry): u64 { registry.total_mandates_revoked }

// ═══════════════════════════════════════════════════════════════════
// Internal helpers
// ═══════════════════════════════════════════════════════════════════

fun vector_contains(v: &vector<address>, elem: &address): bool {
    let mut i = 0;
    let len = vector::length(v);
    while (i < len) {
        if (vector::borrow(v, i) == elem) return true;
        i = i + 1;
    };
    false
}

fun vector_contains_type(v: &vector<TypeName>, elem: &TypeName): bool {
    let mut i = 0;
    let len = vector::length(v);
    while (i < len) {
        if (vector::borrow(v, i) == elem) return true;
        i = i + 1;
    };
    false
}

fun vector_contains_u8(v: &vector<u8>, elem: u8): bool {
    let mut i = 0;
    let len = vector::length(v);
    while (i < len) {
        if (*vector::borrow(v, i) == elem) return true;
        i = i + 1;
    };
    false
}

// ═══════════════════════════════════════════════════════════════════
// Test Helpers
// ═══════════════════════════════════════════════════════════════════

// Error constants mirrored from errors.move for #[expected_failure] annotations
#[test_only] const EInvalidExpiry: u64 = 1;
#[test_only] const EInvalidSpendCap: u64 = 2;
#[test_only] const EInvalidDailyLimit: u64 = 3;
#[test_only] const EInvalidAgent: u64 = 4;
#[test_only] const EEmptyProtocolList: u64 = 6;
#[test_only] const EProtocolListTooLarge: u64 = 7;
#[test_only] const EMaxDepthExceeded: u64 = 9;
#[test_only] const EWrongAgent: u64 = 10;
#[test_only] const EExpiredMandate: u64 = 11;
#[test_only] const EMandateRevoked: u64 = 12;
#[test_only] const EExceedsSpendCap: u64 = 13;
#[test_only] const EDailyLimitExceeded: u64 = 14;
#[test_only] const EAgentScoreTooLow: u64 = 5;
#[test_only] const EProtocolNotAllowed: u64 = 15;
#[test_only] const ECoinNotAllowed: u64 = 16;
#[test_only] const EActionNotAllowed: u64 = 17;
#[test_only] const EZeroAmount: u64 = 18;
#[test_only] const ENotOwner: u64 = 20;
#[test_only] const EAlreadyRevoked: u64 = 21;
#[test_only] const EExceedsParentCap: u64 = 22;
#[test_only] const EExceedsParentDaily: u64 = 23;
#[test_only] const EProtocolNotInParent: u64 = 24;
#[test_only] const EChildOutlivesParent: u64 = 25;

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun min_spend_cap(): u64 { MIN_SPEND_CAP }

#[test_only]
public fun max_protocols(): u64 { MAX_PROTOCOLS }

#[test_only]
public fun max_delegation_depth(): u8 { MAX_DELEGATION_DEPTH }

/// Destroy a mandate in tests (needed because Mandate has key but no drop)
#[test_only]
public fun destroy_mandate_for_testing(mandate: Mandate) {
    let Mandate {
        id,
        owner: _,
        agent: _,
        spend_cap: _,
        daily_limit: _,
        spent_this_epoch: _,
        last_reset_epoch: _,
        allowed_protocols: _,
        allowed_coin_types: _,
        allowed_actions: _,
        created_at_ms: _,
        expires_at_ms: _,
        revoked: _,
        revoked_at_ms: _,
        revoke_reason: _,
        total_actions: _,
        successful_actions: _,
        total_volume: _,
        parent_mandate_id: _,
        max_delegation_depth: _,
        current_depth: _,
        min_agent_score: _,
    } = mandate;
    object::delete(id);
}
