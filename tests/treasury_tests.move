#[test_only]
module movegate::treasury_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use movegate::treasury::{Self, AdminCap, FeeConfig, ProtocolTreasury};

const ADMIN: address = @0xAD;
const RECIPIENT: address = @0xBE;

// ═══════════════════════════════════════════════════════════════════
// Category E — Treasury Edge Cases
// ═══════════════════════════════════════════════════════════════════

#[test]
/// EC-E01: Fee calc with large amount should not overflow (u128 intermediary)
fun test_fee_calculation_no_overflow() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let config = ts::take_shared<FeeConfig>(&scenario);
        // Large amount: 1 billion SUI = 1_000_000_000 * 10^9 MIST
        let large_amount: u64 = 1_000_000_000_000_000_000; // 1B SUI in MIST
        let fee = treasury::calculate_auth_fee(&config, large_amount);
        // 2 bps of 1B SUI = 0.02% = 200_000 SUI = 200_000_000_000_000 MIST
        assert!(fee == 200_000_000_000_000, 0);
        ts::return_shared(config);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::treasury::EZeroBalance)]
/// EC-E02: Withdraw from empty treasury should abort
fun test_withdraw_zero_balance() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        // Treasury is empty — should abort
        treasury::withdraw(&admin_cap, &mut treasury, RECIPIENT, ts::ctx(&mut scenario));
        ts::return_shared(treasury);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

#[test]
/// EC-E03: Non-admin cannot withdraw — AdminCap is type-enforced
/// (This is enforced by Move's type system — non-admin simply cannot pass AdminCap)
/// Instead we test that admin CAN withdraw after fees are collected
fun test_admin_can_withdraw() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        let config = ts::take_shared<FeeConfig>(&scenario);

        // Add funds via creation fee
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        treasury::collect_creation_fee(&mut treasury, &config, &mut payment, ts::ctx(&mut scenario));

        assert!(treasury::treasury_balance(&treasury) == treasury::default_creation_fee(), 0);

        // Admin withdraws
        treasury::withdraw(&admin_cap, &mut treasury, RECIPIENT, ts::ctx(&mut scenario));
        assert!(treasury::treasury_balance(&treasury) == 0, 1);

        coin::burn_for_testing(payment);
        ts::return_shared(treasury);
        ts::return_shared(config);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::treasury::EFeeTooHigh)]
/// Fee BPS update exceeding max should abort
fun test_fee_bps_exceeds_max() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut config = ts::take_shared<FeeConfig>(&scenario);
        // Try to set 501 bps (max is 500)
        treasury::update_auth_fee_bps(&admin_cap, &mut config, 501);
        ts::return_shared(config);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

#[test]
/// Admin can update fee BPS within limits
fun test_fee_bps_update_valid() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut config = ts::take_shared<FeeConfig>(&scenario);
        treasury::update_auth_fee_bps(&admin_cap, &mut config, 100);
        assert!(treasury::auth_fee_bps(&config) == 100, 0);
        ts::return_shared(config);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

#[test]
/// Fee calculation with zero amount returns zero
fun test_fee_zero_amount() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let config = ts::take_shared<FeeConfig>(&scenario);
        let fee = treasury::calculate_auth_fee(&config, 0);
        assert!(fee == 0, 0);
        ts::return_shared(config);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::treasury::EInsufficientFee)]
/// Insufficient payment for creation fee should abort
fun test_insufficient_creation_fee() {
    let mut scenario = ts::begin(ADMIN);
    {
        treasury::init_for_testing(ts::ctx(&mut scenario));
    };
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        let config = ts::take_shared<FeeConfig>(&scenario);
        // Only 1 MIST — far below 10_000_000 required
        let mut payment = coin::mint_for_testing<SUI>(1, ts::ctx(&mut scenario));
        treasury::collect_creation_fee(&mut treasury, &config, &mut payment, ts::ctx(&mut scenario));
        coin::burn_for_testing(payment);
        ts::return_shared(treasury);
        ts::return_shared(config);
    };
    ts::end(scenario);
}
