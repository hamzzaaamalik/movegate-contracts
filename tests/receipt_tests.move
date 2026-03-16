#[test_only]
module movegate::receipt_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use std::type_name;
use movegate::treasury::{Self, FeeConfig, ProtocolTreasury};
use movegate::passport::{Self, AgentRegistry, AgentPassport};
use movegate::mandate::{Self, MandateRegistry};
use movegate::receipt::{Self, ActionReceipt};

const OWNER: address = @0xA1;
const AGENT: address = @0xB2;
const PROTOCOL: address = @0xC3;

fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, OWNER);
    {
        treasury::init_for_testing(ts::ctx(scenario));
        passport::init_for_testing(ts::ctx(scenario));
        mandate::init_for_testing(ts::ctx(scenario));
    };
}

fun create_mandate_and_passport(scenario: &mut ts::Scenario, clock: &Clock) {
    // Ensure passport for AGENT (must be in a prior tx so shared object is available)
    ts::next_tx(scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(scenario);
        passport::ensure_passport(&mut ar, AGENT, clock, ts::ctx(scenario));
        ts::return_shared(ar);
    };

    // Create mandate
    ts::next_tx(scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(scenario);
        let mut ar = ts::take_shared<AgentRegistry>(scenario);
        let mut passport = ts::take_shared<AgentPassport>(scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(scenario);
        let fc = ts::take_shared<FeeConfig>(scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(scenario));

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc,
            AGENT, 100_000, 1_000_000,
            vector[PROTOCOL],
            vector::empty<type_name::TypeName>(),
            vector::empty<u8>(),
            clock.timestamp_ms() + 86_400_000,
            option::none(),
            &mut payment, clock, ts::ctx(scenario),
        );

        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
}

// ═══════════════════════════════════════════════════════════════════
// Receipt Tests
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Success receipt: authorize → create receipt → verify frozen state
fun test_success_receipt() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_mandate_and_passport(&mut scenario, &clock);

    // Agent authorizes and creates success receipt
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 50_000, 0, &clock, ts::ctx(&mut scenario),
        );

        receipt::create_success_receipt(
            token,
            &mut mandate,
            &mut passport,
            &mut ar,
            OWNER,
            PROTOCOL,
            50_000,
            0, // chain_depth
            option::none(), // no parent receipt
            &clock,
            ts::ctx(&mut scenario),
        );

        // Mandate should have 1 successful action
        assert!(mandate::mandate_total_actions(&mandate) == 1, 0);

        // Passport should have 1 action recorded
        assert!(passport::total_actions(&passport) == 1, 1);
        assert!(passport::successful_actions(&passport) == 1, 2);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };

    // Verify the receipt is frozen and accessible
    ts::next_tx(&mut scenario, AGENT);
    {
        let receipt = ts::take_immutable<ActionReceipt>(&scenario);

        assert!(receipt::receipt_agent(&receipt) == AGENT, 3);
        assert!(receipt::receipt_owner(&receipt) == OWNER, 4);
        assert!(receipt::receipt_protocol(&receipt) == PROTOCOL, 5);
        assert!(receipt::receipt_amount(&receipt) == 50_000, 6);
        assert!(receipt::receipt_success(&receipt), 7);
        assert!(receipt::receipt_chain_depth(&receipt) == 0, 8);
        assert!(option::is_none(receipt::receipt_failure_code(&receipt)), 9);
        assert!(option::is_none(receipt::receipt_parent_id(&receipt)), 10);

        ts::return_immutable(receipt);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Failure receipt: authorize → create failure receipt → verify state
fun test_failure_receipt() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_mandate_and_passport(&mut scenario, &clock);

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );

        receipt::create_failure_receipt(
            token,
            &mut passport,
            &mut ar,
            OWNER,
            PROTOCOL,
            30_000,
            42, // failure_code
            0,
            option::none(),
            &clock,
            ts::ctx(&mut scenario),
        );

        // Passport should record failure
        assert!(passport::total_actions(&passport) == 1, 0);
        assert!(passport::failed_actions(&passport) == 1, 1);
        assert!(passport::consecutive_successes(&passport) == 0, 2);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };

    // Verify failure receipt is frozen
    ts::next_tx(&mut scenario, AGENT);
    {
        let receipt = ts::take_immutable<ActionReceipt>(&scenario);

        assert!(!receipt::receipt_success(&receipt), 3);
        assert!(receipt::receipt_amount(&receipt) == 30_000, 4);
        assert!(option::is_some(receipt::receipt_failure_code(&receipt)), 5);
        assert!(*option::borrow(receipt::receipt_failure_code(&receipt)) == 42, 6);

        ts::return_immutable(receipt);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Multiple receipts from same mandate update stats cumulatively
fun test_multiple_receipts_cumulative() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_mandate_and_passport(&mut scenario, &clock);

    // First action — success
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 20_000, 0, &clock, ts::ctx(&mut scenario),
        );

        receipt::create_success_receipt(
            token, &mut mandate, &mut passport, &mut ar,
            OWNER, PROTOCOL, 20_000, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };

    // Second action — success
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );

        receipt::create_success_receipt(
            token, &mut mandate, &mut passport, &mut ar,
            OWNER, PROTOCOL, 30_000, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );

        // Verify cumulative stats
        assert!(mandate::mandate_total_actions(&mandate) == 2, 0);
        assert!(mandate::mandate_total_volume(&mandate) == 50_000, 1);
        assert!(passport::total_actions(&passport) == 2, 2);
        assert!(passport::successful_actions(&passport) == 2, 3);
        assert!(passport::total_volume(&passport) == 50_000, 4);
        assert!(passport::consecutive_successes(&passport) == 2, 5);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
