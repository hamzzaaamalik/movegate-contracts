#[test_only]
module movegate::integration_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use std::type_name;
use movegate::treasury::{Self, AdminCap, FeeConfig, ProtocolTreasury};
use movegate::passport::{Self, AgentRegistry, AgentPassport};
use movegate::mandate::{Self, MandateRegistry};
use movegate::receipt;

const ADMIN: address = @0xAD;
const OWNER: address = @0xA1;
const AGENT: address = @0xB2;
const SUB_AGENT: address = @0xB3;
const PROTOCOL: address = @0xC3;
const PROTOCOL2: address = @0xC4;
const RECIPIENT: address = @0xBE;

fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    {
        treasury::init_for_testing(ts::ctx(scenario));
        passport::init_for_testing(ts::ctx(scenario));
        mandate::init_for_testing(ts::ctx(scenario));
    };
}

fun create_mandate_helper(
    scenario: &mut ts::Scenario,
    clock: &Clock,
    owner: address,
    agent: address,
    spend_cap: u64,
    daily_limit: u64,
    protocols: vector<address>,
    expires_ms: u64,
) {
    // Ensure passport exists for the agent (shared object created here)
    ts::next_tx(scenario, owner);
    {
        let mut ar = ts::take_shared<AgentRegistry>(scenario);
        passport::ensure_passport(&mut ar, agent, clock, ts::ctx(scenario));
        ts::return_shared(ar);
    };

    // Take passport in a subsequent tx and create the mandate
    ts::next_tx(scenario, owner);
    {
        let mut mr = ts::take_shared<MandateRegistry>(scenario);
        let mut ar = ts::take_shared<AgentRegistry>(scenario);
        let mut passport = ts::take_shared<AgentPassport>(scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(scenario);
        let fc = ts::take_shared<FeeConfig>(scenario);
        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(scenario));

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc,
            agent, spend_cap, daily_limit,
            protocols,
            vector::empty<type_name::TypeName>(),
            vector::empty<u8>(),
            expires_ms,
            option::none(),
            &mut payment, clock, ts::ctx(scenario),
        );

        transfer::public_transfer(m, owner);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
}

// ═══════════════════════════════════════════════════════════════════
// S01: End-to-end happy path — create, authorize, receipt, verify
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s01_full_lifecycle() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    // Ensure passport
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Authorize + receipt
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
            token, &mut mandate, &mut passport, &mut ar,
            OWNER, PROTOCOL, 50_000, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );

        assert!(mandate::mandate_total_actions(&mandate) == 1, 0);
        assert!(passport::total_actions(&passport) == 1, 1);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S02: Create → Revoke → Attempt use (should fail)
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::EMandateRevoked)]
fun test_s02_revoke_then_use() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Owner revokes
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mandate = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 1, &clock, ts::ctx(&mut scenario));
        ts::return_to_sender(&scenario, mandate);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };

    // Agent tries to use revoked mandate
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 10_000, 0, &clock, ts::ctx(&mut scenario),
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 10_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S03: Daily limit enforcement across multiple actions
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::EDailyLimitExceeded)]
fun test_s03_daily_limit_across_actions() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // daily_limit = 50_000, spend_cap = 30_000
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 30_000, 50_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // First action: 30_000 (within daily limit)
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 30_000);

        assert!(mandate::mandate_spent_this_epoch(&mandate) == 30_000, 0);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };

    // Second action: 30_000 would push total to 60_000 > 50_000 daily limit
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 30_000, 0, &clock, ts::ctx(&mut scenario),
        );
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 30_000);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S04: Delegation chain — parent → child → agent uses child
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s04_delegation_chain_usage() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL, PROTOCOL2], clock.timestamp_ms() + 86_400_000);

    // Agent delegates to SUB_AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT,
            50_000, 500_000,
            vector[PROTOCOL],
            clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        transfer::public_transfer(child, OWNER);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };

    // Ensure passport for SUB_AGENT
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, SUB_AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // SUB_AGENT uses delegated child mandate
    ts::next_tx(&mut scenario, SUB_AGENT);
    {
        // There are 2 mandates owned by OWNER — take the child (second one created)
        let mut child = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        // Only proceed if this is the child (depth == 1)
        if (mandate::mandate_current_depth(&child) == 1) {
            let token = mandate::authorize_action<SUI>(
                &mut child, &mut passport,
                PROTOCOL, 10_000, 0, &clock, ts::ctx(&mut scenario),
            );

            assert!(mandate::auth_token_agent(&token) == SUB_AGENT, 0);
            let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 10_000);
        };

        ts::return_to_address(OWNER, child);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S05: Treasury fee collection and admin withdrawal
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s05_treasury_lifecycle() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create mandate → collects creation fee
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    // Check treasury balance
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        let expected_fee = treasury::default_creation_fee();
        assert!(treasury::treasury_balance(&treasury) == expected_fee, 0);
        assert!(treasury::total_collected(&treasury) == expected_fee, 1);
        ts::return_shared(treasury);
    };

    // Admin withdraws
    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut treasury = ts::take_shared<ProtocolTreasury>(&scenario);

        treasury::withdraw(&admin_cap, &mut treasury, RECIPIENT, ts::ctx(&mut scenario));

        assert!(treasury::treasury_balance(&treasury) == 0, 2);
        assert!(treasury::total_withdrawn(&treasury) == treasury::default_creation_fee(), 3);

        ts::return_shared(treasury);
        ts::return_to_sender(&scenario, admin_cap);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S06: Passport reputation builds over multiple actions
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s06_reputation_building() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Record 10 successful actions to trigger score computation
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);

        let mut i = 0u64;
        while (i < 10) {
            passport::record_action(
                &mut passport, &mut ar, OWNER, PROTOCOL,
                10_000, true, &clock, ts::ctx(&mut scenario),
            );
            i = i + 1;
        };

        // Score should be computed now
        let score = passport::reputation_score(&passport);
        assert!(score > 0, 0);

        // All 10 success → accuracy = (10*400)/10 = 400
        // Volume, age, streak, diversity also contribute
        assert!(passport::total_actions(&passport) == 10, 1);
        assert!(passport::successful_actions(&passport) == 10, 2);
        assert!(passport::consecutive_successes(&passport) == 10, 3);

        ts::return_shared(passport);
        ts::return_shared(ar);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S07: Multiple mandates for same agent tracked correctly
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s07_multiple_mandates_same_agent() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create first mandate
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    // Create second mandate (different protocol)
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 50_000, 500_000,
        vector[PROTOCOL2], clock.timestamp_ms() + 86_400_000);

    // Verify registry counts 2
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mr = ts::take_shared<MandateRegistry>(&scenario);
        assert!(mandate::registry_total_created(&mr) == 2, 0);
        assert!(mandate::registry_total_active(&mr) == 2, 1);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S08: Fee config update by admin
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s08_fee_config_update() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut fc = ts::take_shared<FeeConfig>(&scenario);

        // Default is 2 bps
        assert!(treasury::auth_fee_bps(&fc) == 2, 0);

        // Update to 100 bps (1%)
        treasury::update_auth_fee_bps(&admin_cap, &mut fc, 100);
        assert!(treasury::auth_fee_bps(&fc) == 100, 1);

        // Update creation fee
        treasury::update_creation_fee(&admin_cap, &mut fc, 20_000_000);
        assert!(treasury::creation_fee(&fc) == 20_000_000, 2);

        ts::return_shared(fc);
        ts::return_to_sender(&scenario, admin_cap);
    };
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S09: Revocation updates both mandate registry and passport
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s09_revocation_updates_all() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mandate = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 1, &clock, ts::ctx(&mut scenario));

        // Verify state
        assert!(mandate::mandate_revoked(&mandate), 0);
        assert!(mandate::registry_total_active(&mr) == 0, 1);
        assert!(mandate::registry_total_revoked(&mr) == 1, 2);
        assert!(passport::revocations_received(&passport) == 1, 3);

        ts::return_to_sender(&scenario, mandate);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S10: Registry global counters consistency
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s10_registry_counters() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Create 3 mandates
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 50_000, 500_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);
    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 30_000, 300_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mr = ts::take_shared<MandateRegistry>(&scenario);
        assert!(mandate::registry_total_created(&mr) == 3, 0);
        assert!(mandate::registry_total_active(&mr) == 3, 1);
        assert!(mandate::registry_total_revoked(&mr) == 0, 2);
        ts::return_shared(mr);
    };

    // Treasury should have 3x creation fee
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        assert!(treasury::treasury_balance(&treasury) == 3 * treasury::default_creation_fee(), 3);
        ts::return_shared(treasury);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S11: Success + failure receipt sequence preserves stats
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s11_mixed_receipt_sequence() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    create_mandate_helper(&mut scenario, &clock, OWNER, AGENT, 100_000, 1_000_000,
        vector[PROTOCOL], clock.timestamp_ms() + 86_400_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Success
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 10_000, 0, &clock, ts::ctx(&mut scenario),
        );
        receipt::create_success_receipt(
            token, &mut mandate, &mut passport, &mut ar,
            OWNER, PROTOCOL, 10_000, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };

    // Failure
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 20_000, 0, &clock, ts::ctx(&mut scenario),
        );
        receipt::create_failure_receipt(
            token, &mut passport, &mut ar,
            OWNER, PROTOCOL, 20_000, 99, 0, option::none(), &clock, ts::ctx(&mut scenario),
        );

        // Check passport: 1 success + 1 failure
        assert!(passport::total_actions(&passport) == 2, 0);
        assert!(passport::successful_actions(&passport) == 1, 1);
        assert!(passport::failed_actions(&passport) == 1, 2);
        assert!(passport::consecutive_successes(&passport) == 0, 3); // reset by failure

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(ar);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// S12: Passport auto-creation is free (no fee for passport)
// ═══════════════════════════════════════════════════════════════════

#[test]
fun test_s12_passport_creation_free() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Check treasury before
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        assert!(treasury::treasury_balance(&treasury) == 0, 0);
        ts::return_shared(treasury);
    };

    // Create passport — should be free
    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        assert!(passport::has_passport(&ar, AGENT), 1);
        ts::return_shared(ar);
    };

    // Treasury should still be 0 — no fee charged
    ts::next_tx(&mut scenario, ADMIN);
    {
        let treasury = ts::take_shared<ProtocolTreasury>(&scenario);
        assert!(treasury::treasury_balance(&treasury) == 0, 2);
        ts::return_shared(treasury);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
