/// Centralized event structs for the MoveGate protocol.
/// No dependencies. All modules emit events through these structs.
module movegate::events;

use sui::event;
use std::type_name::TypeName;

// ═══════════════════════════════════════════════════════════════════
// Passport Events
// ═══════════════════════════════════════════════════════════════════

/// Emitted when a new AgentPassport is auto-created on first action.
public struct PassportCreated has copy, drop {
    passport_id: ID,
    agent: address,
    epoch: u64,
    timestamp_ms: u64,
}

/// Emitted when an agent's reputation score is recalculated.
public struct ScoreUpdated has copy, drop {
    agent: address,
    old_score: u64,
    new_score: u64,
    epoch: u64,
}

/// Emitted when an agent's verification tier is changed by admin.
public struct VerificationTierChanged has copy, drop {
    agent: address,
    old_tier: u8,
    new_tier: u8,
}

// ═══════════════════════════════════════════════════════════════════
// Mandate Events
// ═══════════════════════════════════════════════════════════════════

/// Emitted when a new Mandate is created.
public struct MandateCreated has copy, drop {
    mandate_id: ID,
    owner: address,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    expires_at_ms: u64,
    protocol_count: u64,
}

/// Emitted when a Mandate is revoked by the owner.
public struct MandateRevoked has copy, drop {
    mandate_id: ID,
    owner: address,
    agent: address,
    revoke_reason: u8,
    epoch: u64,
    timestamp_ms: u64,
}

/// Emitted when a child Mandate is delegated from a parent.
public struct MandateDelegated has copy, drop {
    parent_mandate_id: ID,
    child_mandate_id: ID,
    agent: address,
    depth: u8,
}

// ═══════════════════════════════════════════════════════════════════
// Authorization Events
// ═══════════════════════════════════════════════════════════════════

/// Emitted when an AuthToken is issued (action authorized).
public struct ActionAuthorized has copy, drop {
    mandate_id: ID,
    agent: address,
    protocol: address,
    coin_type: TypeName,
    amount: u64,
    action_type: u8,
    agent_score: u64,
    epoch: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Receipt Events
// ═══════════════════════════════════════════════════════════════════

/// Emitted when an ActionReceipt is created and frozen.
public struct ReceiptCreated has copy, drop {
    receipt_id: ID,
    mandate_id: ID,
    agent: address,
    owner: address,
    protocol: address,
    amount: u64,
    success: bool,
    epoch: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Treasury Events
// ═══════════════════════════════════════════════════════════════════

/// Emitted when a fee is collected into the treasury.
public struct FeeCollected has copy, drop {
    amount: u64,
    source: u8, // 0 = mandate creation, 1 = auth fee
    epoch: u64,
}

/// Emitted when the admin withdraws from the treasury.
public struct TreasuryWithdrawal has copy, drop {
    amount: u64,
    recipient: address,
    epoch: u64,
}

/// Emitted when fee configuration is updated by admin.
public struct FeeConfigUpdated has copy, drop {
    old_fee_bps: u64,
    new_fee_bps: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Emit helper functions — called by other modules
// ═══════════════════════════════════════════════════════════════════

public(package) fun emit_passport_created(
    passport_id: ID,
    agent: address,
    epoch: u64,
    timestamp_ms: u64,
) {
    event::emit(PassportCreated { passport_id, agent, epoch, timestamp_ms });
}

public(package) fun emit_score_updated(
    agent: address,
    old_score: u64,
    new_score: u64,
    epoch: u64,
) {
    event::emit(ScoreUpdated { agent, old_score, new_score, epoch });
}

public(package) fun emit_verification_tier_changed(
    agent: address,
    old_tier: u8,
    new_tier: u8,
) {
    event::emit(VerificationTierChanged { agent, old_tier, new_tier });
}

public(package) fun emit_mandate_created(
    mandate_id: ID,
    owner: address,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    expires_at_ms: u64,
    protocol_count: u64,
) {
    event::emit(MandateCreated {
        mandate_id, owner, agent, spend_cap, daily_limit, expires_at_ms, protocol_count,
    });
}

public(package) fun emit_mandate_revoked(
    mandate_id: ID,
    owner: address,
    agent: address,
    revoke_reason: u8,
    epoch: u64,
    timestamp_ms: u64,
) {
    event::emit(MandateRevoked {
        mandate_id, owner, agent, revoke_reason, epoch, timestamp_ms,
    });
}

public(package) fun emit_mandate_delegated(
    parent_mandate_id: ID,
    child_mandate_id: ID,
    agent: address,
    depth: u8,
) {
    event::emit(MandateDelegated { parent_mandate_id, child_mandate_id, agent, depth });
}

public(package) fun emit_action_authorized(
    mandate_id: ID,
    agent: address,
    protocol: address,
    coin_type: TypeName,
    amount: u64,
    action_type: u8,
    agent_score: u64,
    epoch: u64,
) {
    event::emit(ActionAuthorized {
        mandate_id, agent, protocol, coin_type, amount, action_type, agent_score, epoch,
    });
}

public(package) fun emit_receipt_created(
    receipt_id: ID,
    mandate_id: ID,
    agent: address,
    owner: address,
    protocol: address,
    amount: u64,
    success: bool,
    epoch: u64,
) {
    event::emit(ReceiptCreated {
        receipt_id, mandate_id, agent, owner, protocol, amount, success, epoch,
    });
}

public(package) fun emit_fee_collected(amount: u64, source: u8, epoch: u64) {
    event::emit(FeeCollected { amount, source, epoch });
}

public(package) fun emit_treasury_withdrawal(amount: u64, recipient: address, epoch: u64) {
    event::emit(TreasuryWithdrawal { amount, recipient, epoch });
}

public(package) fun emit_fee_config_updated(old_fee_bps: u64, new_fee_bps: u64) {
    event::emit(FeeConfigUpdated { old_fee_bps, new_fee_bps });
}
