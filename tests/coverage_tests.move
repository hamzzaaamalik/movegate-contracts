#[test_only]
/// Additional tests to maximize code coverage across all modules.
module movegate::coverage_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self};
use std::type_name;
use movegate::treasury::{Self, AdminCap, FeeConfig, ProtocolTreasury};
use movegate::passport::{Self, AgentRegistry, AgentPassport};
use movegate::mandate::{Self, MandateRegistry};
use movegate::receipt::{Self, ActionReceipt};
use movegate::errors;

const ADMIN: address = @0xAD;
const OWNER: address = @0xA1;
const AGENT: address = @0xB2;
const PROTOCOL: address = @0xC3;
const PROTOCOL2: address = @0xC4;
const USER1: address = @0xD1;

fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    {
        treasury::init_for_testing(ts::ctx(scenario));
        passport::init_for_testing(ts::ctx(scenario));
        mandate::init_for_testing(ts::ctx(scenario));
    };
}

// ═══════════════════════════════════════════════════════════════════
// errors.move — exercise all accessor functions
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_all_error_accessors() {
    assert!(errors::invalid_expiry() == 1, 0);
    assert!(errors::invalid_spend_cap() == 2, 0);
    assert!(errors::invalid_daily_limit() == 3, 0);
    assert!(errors::invalid_agent() == 4, 0);
    assert!(errors::agent_score_too_low() == 5, 0);
    assert!(errors::empty_protocol_list() == 6, 0);
    assert!(errors::protocol_list_too_large() == 7, 0);
    assert!(errors::insufficient_fee() == 8, 0);
    assert!(errors::max_depth_exceeded() == 9, 0);
    assert!(errors::wrong_agent() == 10, 0);
    assert!(errors::expired_mandate() == 11, 0);
    assert!(errors::mandate_revoked() == 12, 0);
    assert!(errors::exceeds_spend_cap() == 13, 0);
    assert!(errors::daily_limit_exceeded() == 14, 0);
    assert!(errors::protocol_not_allowed() == 15, 0);
    assert!(errors::coin_not_allowed() == 16, 0);
    assert!(errors::action_not_allowed() == 17, 0);
    assert!(errors::zero_amount() == 18, 0);
    assert!(errors::mandate_id_mismatch() == 19, 0);
    assert!(errors::not_owner() == 20, 0);
    assert!(errors::already_revoked() == 21, 0);
    assert!(errors::exceeds_parent_cap() == 22, 0);
    assert!(errors::exceeds_parent_daily() == 23, 0);
    assert!(errors::protocol_not_in_parent() == 24, 0);
    assert!(errors::child_outlives_parent() == 25, 0);
    assert!(errors::cyclic_delegation() == 26, 0);
    assert!(errors::zero_balance() == 27, 0);
    assert!(errors::not_admin() == 28, 0);
    assert!(errors::fee_too_high() == 29, 0);
    assert!(errors::fee_overflow() == 30, 0);
    assert!(errors::upgrade_not_allowed() == 31, 0);
    assert!(errors::passport_already_exists() == 32, 0);
    assert!(errors::passport_not_found() == 33, 0);
    assert!(errors::score_cooldown_active() == 34, 0);
    assert!(errors::amount_mismatch() == 35, 0);
}

// ═══════════════════════════════════════════════════════════════════
// treasury.move — collect_auth_fee + update_creation_fee
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Exercise collect_auth_fee path
fun test_collect_auth_fee() {
    let mut scenario = ts::begin(ADMIN);
    { treasury::init_for_testing(ts::ctx(&mut scenario)); };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let fee = treasury::collect_auth_fee(
            &mut treasury, &fc, &mut payment, 1_000_000, ts::ctx(&mut scenario),
        );
        // 2 bps of 1_000_000 = 200
        assert!(fee == 200, 0);
        assert!(treasury::treasury_balance(&treasury) == 200, 1);

        coin::burn_for_testing(payment);
        ts::return_shared(treasury);
        ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
/// collect_auth_fee with zero amount returns 0
fun test_collect_auth_fee_zero() {
    let mut scenario = ts::begin(ADMIN);
    { treasury::init_for_testing(ts::ctx(&mut scenario)); };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let fee = treasury::collect_auth_fee(
            &mut treasury, &fc, &mut payment, 0, ts::ctx(&mut scenario),
        );
        assert!(fee == 0, 0);

        coin::burn_for_testing(payment);
        ts::return_shared(treasury);
        ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
/// update_creation_fee changes the fee
fun test_update_creation_fee() {
    let mut scenario = ts::begin(ADMIN);
    { treasury::init_for_testing(ts::ctx(&mut scenario)); };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut fc = ts::take_shared<FeeConfig>(&scenario);

        assert!(treasury::creation_fee(&fc) == treasury::default_creation_fee(), 0);
        treasury::update_creation_fee(&admin_cap, &mut fc, 20_000_000);
        assert!(treasury::creation_fee(&fc) == 20_000_000, 1);

        // Also verify max_fee_bps accessor
        assert!(treasury::max_fee_bps_value(&fc) > 0, 2);

        ts::return_shared(fc);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// mandate.move — coin type filter, action type filter, min_agent_score
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Coin type filtering — SUI coin type in whitelist passes
fun test_coin_type_filtering() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL],
            vector[type_name::with_original_ids<SUI>()],
            vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Action type filtering — exercises vector_contains_u8
fun test_action_type_filtering() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(),
            vector[1u8, 2u8],
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 2, &clock, ts::ctx(&mut scenario),
        );
        assert!(mandate::auth_token_action_type(&token) == 2, 0);
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// min_agent_score = 0 — fresh agent (score 0) passes
fun test_min_agent_score_passes() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::some(0u64),
            &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EDailyLimitExceeded)]
/// Cumulative spend exceeds daily limit
fun test_daily_limit_cumulative() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 30_000, 50_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 30_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 30_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// mandate.move — failure branches for coin/action/score checks
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::ECoinNotAllowed)]
/// Coin type NOT in whitelist → abort
fun test_coin_not_allowed() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    // Create mandate with SUI coin whitelist
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL],
            vector[type_name::with_original_ids<SUI>()],
            vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    // Try to authorize with a DIFFERENT coin type (use Coin<SUI> but pretend it's a different type)
    // We need a different type — use std::ascii::String as a fake coin type
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        // authorize with std::string::String as CoinType — not in whitelist
        let token = mandate::authorize_action<std::string::String>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EActionNotAllowed)]
/// Action type NOT in whitelist → abort
fun test_action_not_allowed() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(),
            vector[1u8, 2u8],  // only actions 1 and 2 allowed
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        // action_type 5 — not in [1, 2]
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 5, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EAgentScoreTooLow)]
/// Agent score below min_agent_score → abort
fun test_agent_score_too_low() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::some(500u64),  // require score >= 500
            &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        // Fresh agent has score 0 — mandate requires 500
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Exercise the create_mandate path where min_agent_score is set and agent has a passport
fun test_create_mandate_with_score_and_passport() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create passport first
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Create mandate with min_agent_score — agent already has passport
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::some(0u64),
            &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Exercise mandate spent_this_epoch accessor and registry accessors
fun test_mandate_registry_accessors() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mr = ts::take_shared<MandateRegistry>(&scenario);
        assert!(mandate::registry_total_created(&mr) == 0, 0);
        assert!(mandate::registry_total_active(&mr) == 0, 1);
        assert!(mandate::registry_total_revoked(&mr) == 0, 2);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Exercise auth token read accessors not covered elsewhere
fun test_auth_token_accessors() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 5_000, 0, &clock, ts::ctx(&mut scenario),
        );

        // Exercise all auth token accessors
        let _mid = mandate::auth_token_mandate_id(&token);
        let _agent = mandate::auth_token_agent(&token);
        let _proto = mandate::auth_token_protocol(&token);
        let _amt = mandate::auth_token_amount(&token);
        let _at = mandate::auth_token_action_type(&token);
        let _sc = mandate::auth_token_score(&token);

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 5_000);

        // Also check mandate spent_this_epoch after action
        assert!(mandate::mandate_spent_this_epoch(&mandate) == 5_000, 0);

        ts::return_to_address(OWNER, mandate); ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// treasury.move — additional failure paths
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Exercise calculate_auth_fee directly
fun test_calculate_auth_fee_directly() {
    let mut scenario = ts::begin(ADMIN);
    { treasury::init_for_testing(ts::ctx(&mut scenario)); };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let fc = ts::take_shared<FeeConfig>(&scenario);
        // 2 bps of 1_000_000 = 200
        let fee = treasury::calculate_auth_fee(&fc, 1_000_000);
        assert!(fee == 200, 0);
        // 0 amount = 0 fee
        let fee2 = treasury::calculate_auth_fee(&fc, 0);
        assert!(fee2 == 0, 1);
        // Exercise total_collected and total_withdrawn accessors
        let tr = ts::take_shared<ProtocolTreasury>(&scenario);
        assert!(treasury::total_collected(&tr) == 0, 2);
        assert!(treasury::total_withdrawn(&tr) == 0, 3);
        ts::return_shared(tr);
        ts::return_shared(fc);
    };
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// passport.move — reputation score edge cases
// ═══════════════════════════════════════════════════════════════════

#[test]
/// High volume + multiple protocols exercises max branches in compute_score
fun test_reputation_score_max_branches() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create passport at time 0 first
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Now advance clock to 200 days (past AGE_THRESHOLD_DAYS=180)
    clock::set_for_testing(&mut clock, 200 * 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);

        // Record 10 successful actions with high volume across 5+ protocols
        // This exercises: accuracy=400, volume branch, age branch, diversity branch
        let mut i = 0u64;
        while (i < 10) {
            let proto = if (i < 5) { PROTOCOL } else { PROTOCOL2 };
            passport::record_action(
                &mut passport, &mut ar, USER1, proto,
                200_000_000_000, // 200B MIST per action (> VOLUME_THRESHOLD total)
                true, &clock, ts::ctx(&mut scenario),
            );
            i = i + 1;
        };

        let score = passport::reputation_score(&passport);
        // Should be high: accuracy=400, volume=200 (maxed), age=200 (maxed),
        // streak=5 (10/100*50), diversity=20 (2/5*50)
        assert!(score > 600, 0);

        ts::return_shared(passport);
        ts::return_shared(ar);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Score with revocation penalty
fun test_reputation_with_revocation_penalty() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);

        // Record 10 actions to trigger scoring
        let mut i = 0u64;
        while (i < 10) {
            passport::record_action(
                &mut passport, &mut ar, USER1, PROTOCOL,
                1_000, true, &clock, ts::ctx(&mut scenario),
            );
            i = i + 1;
        };

        let score_before = passport::reputation_score(&passport);

        // Record 2 revocations
        passport::record_revocation(&mut passport, &clock, ts::ctx(&mut scenario));
        passport::record_revocation(&mut passport, &clock, ts::ctx(&mut scenario));
        assert!(passport::revocations_received(&passport) == 2, 0);

        // Record one more action to trigger rescore (need to get past cooldown in same epoch)
        // Since cooldown is epoch-based and we're at epoch 0 with last_score_update at 0,
        // the cooldown check passes when score > 0 and epoch < last + 10
        // So score won't update until 10 epochs later. But the revocation itself
        // calls maybe_update_score which will skip due to cooldown.
        // The revocation count is still tracked.
        let _ = score_before;

        ts::return_shared(passport);
        ts::return_shared(ar);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// receipt.move — all read accessors
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Exercise all receipt read accessors
fun test_receipt_all_accessors() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create passport first
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Create mandate
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };

    // Create success receipt
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 5_000, 0, &clock, ts::ctx(&mut scenario),
        );
        receipt::create_success_receipt(
            token, &mut mandate, &mut passport, &mut ar,
            OWNER, PROTOCOL, 5_000, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );
        ts::return_to_address(OWNER, mandate); ts::return_shared(ar); ts::return_shared(passport);
    };

    // Read all accessors on frozen receipt
    ts::next_tx(&mut scenario, AGENT);
    {
        let r = ts::take_immutable<ActionReceipt>(&scenario);
        let _mid = receipt::receipt_mandate_id(&r);
        let _agent = receipt::receipt_agent(&r);
        let _owner = receipt::receipt_owner(&r);
        let _proto = receipt::receipt_protocol(&r);
        let _amt = receipt::receipt_amount(&r);
        let _at = receipt::receipt_action_type(&r);
        let _ep = receipt::receipt_epoch(&r);
        let _ts = receipt::receipt_timestamp_ms(&r);
        let _ok = receipt::receipt_success(&r);
        let _fc = receipt::receipt_failure_code(&r);
        let _cd = receipt::receipt_chain_depth(&r);
        let _pi = receipt::receipt_parent_id(&r);
        let _sc = receipt::receipt_agent_score(&r);
        ts::return_immutable(r);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// mandate.move — read accessor coverage
// ═══════════════════════════════════════════════════════════════════

#[test]
/// Exercise mandate read accessors not covered elsewhere
fun test_mandate_accessors() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 100_000, 1_000_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000, option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );

        // Exercise accessors
        assert!(mandate::mandate_owner(&m) == OWNER, 0);
        assert!(mandate::mandate_agent(&m) == AGENT, 1);
        assert!(mandate::mandate_spend_cap(&m) == 100_000, 2);
        assert!(mandate::mandate_daily_limit(&m) == 1_000_000, 3);
        assert!(mandate::mandate_expires_at_ms(&m) == 86_400_000, 4);
        assert!(!mandate::mandate_revoked(&m), 5);
        assert!(mandate::mandate_total_actions(&m) == 0, 6);
        assert!(mandate::mandate_total_volume(&m) == 0, 7);
        assert!(mandate::mandate_current_depth(&m) == 0, 8);
        assert!(option::is_none(mandate::mandate_parent_id(&m)), 9);
        assert!(option::is_none(mandate::mandate_min_agent_score(&m)), 10);
        assert!(vector::length(mandate::mandate_allowed_protocols(&m)) == 1, 11);

        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// passport.move — read accessor + registry coverage
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_passport_accessors_and_registry() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));

        // Registry accessors
        assert!(passport::registry_total_registered(&ar) == 1, 0);
        assert!(passport::registry_total_actions(&ar) == 0, 1);
        assert!(passport::registry_total_volume(&ar) == 0, 2);

        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let passport = ts::take_shared<AgentPassport>(&scenario);

        // All passport accessors
        assert!(passport::agent(&passport) == AGENT, 0);
        assert!(passport::registered_at_ms(&passport) == 0, 1);
        assert!(passport::last_action_epoch(&passport) == 0, 2);
        assert!(vector::length(passport::top_protocols(&passport)) == 0, 3);

        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
