/// Immutable action audit trail for MoveGate.
/// Every authorized action produces a frozen ActionReceipt — permanent, tamper-proof.
/// Dependencies: errors, events, mandate, passport
module movegate::receipt;

use sui::clock::Clock;
use std::type_name::TypeName;
use movegate::events;
use movegate::mandate::{Self, Mandate, AuthToken};
use movegate::passport::{Self, AgentPassport, AgentRegistry};

// ═══════════════════════════════════════════════════════════════════
// Structs
// ═══════════════════════════════════════════════════════════════════

/// Immutable record of every authorized action. Frozen via transfer::freeze_object.
/// Once created, can never be modified or deleted — cryptographic proof of history.
public struct ActionReceipt has key {
    id: UID,
    mandate_id: ID,
    agent: address,
    owner: address,
    protocol: address,
    coin_type: TypeName,
    amount: u64,
    action_type: u8,
    epoch: u64,
    timestamp_ms: u64,
    success: bool,
    failure_code: Option<u64>,
    chain_depth: u8,
    parent_receipt_id: Option<ID>,
    agent_score_at_time: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Create Receipt — Consumes AuthToken and freezes receipt
// ═══════════════════════════════════════════════════════════════════

/// Create an ActionReceipt for a successful action.
/// Consumes the hot potato AuthToken, updates passport and mandate stats,
/// then freezes the receipt permanently on-chain.
public fun create_success_receipt(
    token: AuthToken,
    mandate: &mut Mandate,
    passport: &mut AgentPassport,
    agent_registry: &mut AgentRegistry,
    owner: address,
    expected_protocol: address,
    expected_amount: u64,
    chain_depth: u8,
    parent_receipt_id: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (
        mandate_id,
        agent,
        protocol,
        coin_type,
        amount,
        action_type,
        _authorized_at_epoch,
        agent_score_at_auth,
    ) = mandate::consume_auth_token(token, expected_protocol, expected_amount);

    // Update mandate success counter
    mandate::record_success(mandate);

    // Update passport with action data
    passport::record_action(
        passport,
        agent_registry,
        owner,
        protocol,
        amount,
        true, // success
        clock,
        ctx,
    );

    let receipt = ActionReceipt {
        id: object::new(ctx),
        mandate_id,
        agent,
        owner,
        protocol,
        coin_type,
        amount,
        action_type,
        epoch: ctx.epoch(),
        timestamp_ms: clock.timestamp_ms(),
        success: true,
        failure_code: option::none(),
        chain_depth,
        parent_receipt_id,
        agent_score_at_time: agent_score_at_auth,
    };

    let receipt_id = object::id(&receipt);

    events::emit_receipt_created(
        receipt_id,
        mandate_id,
        agent,
        owner,
        protocol,
        amount,
        true,
        ctx.epoch(),
    );

    // Freeze permanently — immutable on-chain forever
    transfer::freeze_object(receipt);
}

/// Create an ActionReceipt for a failed action.
/// Consumes the AuthToken, records failure on passport.
public fun create_failure_receipt(
    token: AuthToken,
    passport: &mut AgentPassport,
    agent_registry: &mut AgentRegistry,
    owner: address,
    expected_protocol: address,
    expected_amount: u64,
    failure_code: u64,
    chain_depth: u8,
    parent_receipt_id: Option<ID>,
    clock: &Clock,
    ctx: &mut TxContext,
) {
    let (
        mandate_id,
        agent,
        protocol,
        coin_type,
        amount,
        action_type,
        _authorized_at_epoch,
        agent_score_at_auth,
    ) = mandate::consume_auth_token(token, expected_protocol, expected_amount);

    // Update passport with failed action data
    passport::record_action(
        passport,
        agent_registry,
        owner,
        protocol,
        amount,
        false, // failure
        clock,
        ctx,
    );

    let receipt = ActionReceipt {
        id: object::new(ctx),
        mandate_id,
        agent,
        owner,
        protocol,
        coin_type,
        amount,
        action_type,
        epoch: ctx.epoch(),
        timestamp_ms: clock.timestamp_ms(),
        success: false,
        failure_code: option::some(failure_code),
        chain_depth,
        parent_receipt_id,
        agent_score_at_time: agent_score_at_auth,
    };

    let receipt_id = object::id(&receipt);

    events::emit_receipt_created(
        receipt_id,
        mandate_id,
        agent,
        owner,
        protocol,
        amount,
        false,
        ctx.epoch(),
    );

    // Freeze permanently
    transfer::freeze_object(receipt);
}

// ═══════════════════════════════════════════════════════════════════
// Read Accessors — receipts are frozen, so only & references
// ═══════════════════════════════════════════════════════════════════

public fun receipt_mandate_id(receipt: &ActionReceipt): ID { receipt.mandate_id }
public fun receipt_agent(receipt: &ActionReceipt): address { receipt.agent }
public fun receipt_owner(receipt: &ActionReceipt): address { receipt.owner }
public fun receipt_protocol(receipt: &ActionReceipt): address { receipt.protocol }
public fun receipt_amount(receipt: &ActionReceipt): u64 { receipt.amount }
public fun receipt_action_type(receipt: &ActionReceipt): u8 { receipt.action_type }
public fun receipt_epoch(receipt: &ActionReceipt): u64 { receipt.epoch }
public fun receipt_timestamp_ms(receipt: &ActionReceipt): u64 { receipt.timestamp_ms }
public fun receipt_success(receipt: &ActionReceipt): bool { receipt.success }
public fun receipt_failure_code(receipt: &ActionReceipt): &Option<u64> { &receipt.failure_code }
public fun receipt_chain_depth(receipt: &ActionReceipt): u8 { receipt.chain_depth }
public fun receipt_parent_id(receipt: &ActionReceipt): &Option<ID> { &receipt.parent_receipt_id }
public fun receipt_agent_score(receipt: &ActionReceipt): u64 { receipt.agent_score_at_time }
