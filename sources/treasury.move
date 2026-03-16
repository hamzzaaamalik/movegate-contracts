/// Fee collection, configuration, and treasury management for MoveGate.
/// Dependencies: errors
module movegate::treasury;

use sui::coin::{Self, Coin};
use sui::sui::SUI;
use sui::balance::{Self, Balance};
use movegate::errors;
use movegate::events;

// ═══════════════════════════════════════════════════════════════════
// Constants
// ═══════════════════════════════════════════════════════════════════

/// Default mandate creation fee: 0.01 SUI = 10_000_000 MIST
const DEFAULT_CREATION_FEE: u64 = 10_000_000;

/// Default authorization fee: 2 basis points (0.02%)
const DEFAULT_AUTH_FEE_BPS: u64 = 2;

/// Maximum fee BPS that admin can set (5% = 500 bps)
const MAX_FEE_BPS: u64 = 500;

/// Fee source identifiers
const FEE_SOURCE_CREATION: u8 = 0;
const FEE_SOURCE_AUTH: u8 = 1;

// ═══════════════════════════════════════════════════════════════════
// Structs
// ═══════════════════════════════════════════════════════════════════

/// Admin capability — created once in init(), transferred to deployer.
/// Required for fee configuration changes and treasury withdrawal.
public struct AdminCap has key, store {
    id: UID,
}

/// Fee configuration — shared object, readable by all modules.
public struct FeeConfig has key {
    id: UID,
    /// Mandate creation fee in MIST
    creation_fee: u64,
    /// Authorization fee in basis points (1 bps = 0.01%)
    auth_fee_bps: u64,
    /// Maximum allowed fee BPS — admin cannot exceed this
    max_fee_bps: u64,
}

/// Protocol treasury — shared object, collects all fees.
public struct ProtocolTreasury has key {
    id: UID,
    /// Accumulated SUI balance from fees
    balance: Balance<SUI>,
    /// Total fees collected all-time in MIST
    total_collected: u64,
    /// Total fees withdrawn all-time in MIST
    total_withdrawn: u64,
}

// ═══════════════════════════════════════════════════════════════════
// Init — called once on publish
// ═══════════════════════════════════════════════════════════════════

fun init(ctx: &mut TxContext) {
    // Create and transfer AdminCap to deployer
    transfer::transfer(
        AdminCap { id: object::new(ctx) },
        ctx.sender(),
    );

    // Create shared FeeConfig
    transfer::share_object(FeeConfig {
        id: object::new(ctx),
        creation_fee: DEFAULT_CREATION_FEE,
        auth_fee_bps: DEFAULT_AUTH_FEE_BPS,
        max_fee_bps: MAX_FEE_BPS,
    });

    // Create shared ProtocolTreasury
    transfer::share_object(ProtocolTreasury {
        id: object::new(ctx),
        balance: balance::zero<SUI>(),
        total_collected: 0,
        total_withdrawn: 0,
    });
}

// ═══════════════════════════════════════════════════════════════════
// Fee Collection — called by mandate module
// ═══════════════════════════════════════════════════════════════════

/// Collect a mandate creation fee. Aborts if payment is below creation_fee.
/// Returns the change (remaining coin after fee extraction).
public(package) fun collect_creation_fee(
    treasury: &mut ProtocolTreasury,
    fee_config: &FeeConfig,
    payment: &mut Coin<SUI>,
    ctx: &TxContext,
) {
    let fee_amount = fee_config.creation_fee;
    assert!(coin::value(payment) >= fee_amount, errors::insufficient_fee());

    let fee_balance = coin::balance_mut(payment).split(fee_amount);
    treasury.balance.join(fee_balance);
    treasury.total_collected = treasury.total_collected + fee_amount;

    events::emit_fee_collected(fee_amount, FEE_SOURCE_CREATION, ctx.epoch());
}

/// Calculate and collect the authorization micro-fee from a coin.
/// Uses u128 intermediary to prevent overflow.
/// Returns the fee amount collected.
public(package) fun collect_auth_fee(
    treasury: &mut ProtocolTreasury,
    fee_config: &FeeConfig,
    payment: &mut Coin<SUI>,
    action_amount: u64,
    ctx: &TxContext,
): u64 {
    let fee_amount = calculate_auth_fee(fee_config, action_amount);
    if (fee_amount == 0) return 0;

    assert!(coin::value(payment) >= fee_amount, errors::insufficient_fee());

    let fee_balance = coin::balance_mut(payment).split(fee_amount);
    treasury.balance.join(fee_balance);
    treasury.total_collected = treasury.total_collected + fee_amount;

    events::emit_fee_collected(fee_amount, FEE_SOURCE_AUTH, ctx.epoch());
    fee_amount
}

/// Calculate authorization fee using u128 intermediary. Multiply before divide.
public fun calculate_auth_fee(fee_config: &FeeConfig, amount: u64): u64 {
    if (fee_config.auth_fee_bps == 0 || amount == 0) return 0;

    let fee = ((amount as u128) * (fee_config.auth_fee_bps as u128)) / 10_000u128;
    (fee as u64)
}

// ═══════════════════════════════════════════════════════════════════
// Admin Functions — require AdminCap
// ═══════════════════════════════════════════════════════════════════

/// Withdraw all accumulated fees to a recipient address.
public fun withdraw(
    _admin: &AdminCap,
    treasury: &mut ProtocolTreasury,
    recipient: address,
    ctx: &mut TxContext,
) {
    let amount = treasury.balance.value();
    assert!(amount > 0, errors::zero_balance());

    let withdrawn = coin::from_balance(treasury.balance.withdraw_all(), ctx);
    treasury.total_withdrawn = treasury.total_withdrawn + amount;

    events::emit_treasury_withdrawal(amount, recipient, ctx.epoch());
    transfer::public_transfer(withdrawn, recipient);
}

/// Update the authorization fee BPS. Cannot exceed max_fee_bps.
public fun update_auth_fee_bps(
    _admin: &AdminCap,
    fee_config: &mut FeeConfig,
    new_fee_bps: u64,
) {
    assert!(new_fee_bps <= fee_config.max_fee_bps, errors::fee_too_high());

    let old = fee_config.auth_fee_bps;
    fee_config.auth_fee_bps = new_fee_bps;
    events::emit_fee_config_updated(old, new_fee_bps);
}

/// Update the mandate creation fee.
public fun update_creation_fee(
    _admin: &AdminCap,
    fee_config: &mut FeeConfig,
    new_fee: u64,
) {
    fee_config.creation_fee = new_fee;
}

// ═══════════════════════════════════════════════════════════════════
// Read Accessors
// ═══════════════════════════════════════════════════════════════════

public fun creation_fee(config: &FeeConfig): u64 { config.creation_fee }
public fun auth_fee_bps(config: &FeeConfig): u64 { config.auth_fee_bps }
public fun max_fee_bps_value(config: &FeeConfig): u64 { config.max_fee_bps }
public fun treasury_balance(treasury: &ProtocolTreasury): u64 { treasury.balance.value() }
public fun total_collected(treasury: &ProtocolTreasury): u64 { treasury.total_collected }
public fun total_withdrawn(treasury: &ProtocolTreasury): u64 { treasury.total_withdrawn }

// ═══════════════════════════════════════════════════════════════════
// Test Helpers
// ═══════════════════════════════════════════════════════════════════

// Error constants mirrored from errors.move for #[expected_failure] annotations
#[test_only] const EInsufficientFee: u64 = 8;
#[test_only] const EZeroBalance: u64 = 27;
#[test_only] const EFeeTooHigh: u64 = 29;

#[test_only]
public fun init_for_testing(ctx: &mut TxContext) {
    init(ctx);
}

#[test_only]
public fun default_creation_fee(): u64 { DEFAULT_CREATION_FEE }

#[test_only]
public fun default_auth_fee_bps(): u64 { DEFAULT_AUTH_FEE_BPS }
