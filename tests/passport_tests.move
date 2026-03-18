#[test_only]
module movegate::passport_tests;

use sui::test_scenario::{Self as ts};
use sui::clock::{Self};
use movegate::passport::{Self, AgentRegistry, AgentPassport};
use movegate::treasury::{Self, AdminCap};

const ADMIN: address = @0xAD;
const AGENT1: address = @0xB1;
const AGENT2: address = @0xB2;
const PROTOCOL1: address = @0xC1;
const PROTOCOL2: address = @0xC2;
const USER1: address = @0xD1;
const USER2: address = @0xD2;

/// Helper: initialize passport and treasury (for AdminCap)
fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, ADMIN);
    {
        passport::init_for_testing(ts::ctx(scenario));
        treasury::init_for_testing(ts::ctx(scenario));
    };
}

// ═══════════════════════════════════════════════════════════════════
// Category G — Passport Edge Cases
// ═══════════════════════════════════════════════════════════════════

#[test]
/// EC-G01: Auto-create passport on first action — passport should exist after ensure_passport
fun test_auto_create_passport() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        assert!(!passport::has_passport(&registry, AGENT1), 0);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        assert!(passport::has_passport(&registry, AGENT1), 1);
        assert!(passport::registry_total_registered(&registry) == 1, 2);

        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G02: Second ensure_passport call does NOT create duplicate
fun test_no_duplicate_passport() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        // Call again — should be a no-op
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));

        assert!(passport::registry_total_registered(&registry) == 1, 0);
        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G03: Two different agents get two separate passports
fun test_two_agents_two_passports() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        passport::ensure_passport(&mut registry, AGENT2, &clock, ts::ctx(&mut scenario));

        assert!(passport::has_passport(&registry, AGENT1), 0);
        assert!(passport::has_passport(&registry, AGENT2), 1);
        assert!(passport::registry_total_registered(&registry) == 2, 2);

        // Passport IDs should be different
        let id1 = passport::get_passport_id(&registry, AGENT1);
        let id2 = passport::get_passport_id(&registry, AGENT2);
        assert!(id1 != id2, 3);

        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G04: Fresh passport has zero stats
fun test_fresh_passport_zero_stats() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let passport = ts::take_shared<AgentPassport>(&scenario);

        assert!(passport::agent(&passport) == AGENT1, 0);
        assert!(passport::total_actions(&passport) == 0, 1);
        assert!(passport::successful_actions(&passport) == 0, 2);
        assert!(passport::failed_actions(&passport) == 0, 3);
        assert!(passport::total_volume(&passport) == 0, 4);
        assert!(passport::reputation_score(&passport) == 0, 5);
        assert!(passport::verification_tier(&passport) == 0, 6);
        assert!(!passport::verified(&passport), 7);
        assert!(passport::unique_users(&passport) == 0, 8);
        assert!(passport::unique_protocols(&passport) == 0, 9);
        assert!(passport::revocations_received(&passport) == 0, 10);
        assert!(passport::consecutive_successes(&passport) == 0, 11);
        assert!(passport::active_mandate_count(&passport) == 0, 12);

        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G05: record_action updates stats correctly (success path)
fun test_record_action_success() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        passport::record_action(
            &mut passport, &mut registry,
            USER1, PROTOCOL1, 5_000, true, &clock, ts::ctx(&mut scenario),
        );

        assert!(passport::total_actions(&passport) == 1, 0);
        assert!(passport::successful_actions(&passport) == 1, 1);
        assert!(passport::failed_actions(&passport) == 0, 2);
        assert!(passport::total_volume(&passport) == 5_000, 3);
        assert!(passport::consecutive_successes(&passport) == 1, 4);
        assert!(passport::unique_users(&passport) == 1, 5);
        assert!(passport::unique_protocols(&passport) == 1, 6);
        assert!(passport::registry_total_actions(&registry) == 1, 7);
        assert!(passport::registry_total_volume(&registry) == 5_000, 8);

        ts::return_shared(passport);
        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G06: Failure resets consecutive success streak to 0
fun test_streak_reset_on_failure() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        // 3 successes
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));
        assert!(passport::consecutive_successes(&passport) == 3, 0);

        // 1 failure — resets streak
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, false, &clock, ts::ctx(&mut scenario));
        assert!(passport::consecutive_successes(&passport) == 0, 1);
        assert!(passport::failed_actions(&passport) == 1, 2);
        assert!(passport::total_actions(&passport) == 4, 3);

        ts::return_shared(passport);
        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G07: Unique user/protocol tracking — same user twice counts once
fun test_unique_tracking_dedup() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        // Same user + same protocol, twice
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 2_000, true, &clock, ts::ctx(&mut scenario));
        assert!(passport::unique_users(&passport) == 1, 0);
        assert!(passport::unique_protocols(&passport) == 1, 1);

        // Different user + different protocol
        passport::record_action(&mut passport, &mut registry, USER2, PROTOCOL2, 3_000, true, &clock, ts::ctx(&mut scenario));
        assert!(passport::unique_users(&passport) == 2, 2);
        assert!(passport::unique_protocols(&passport) == 2, 3);

        ts::return_shared(passport);
        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G08: Revocation increases revocations_received
fun test_revocation_updates_passport() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        // Increment mandate count first (simulating mandate creation)
        passport::increment_mandate_count(&mut passport);
        assert!(passport::active_mandate_count(&passport) == 1, 0);

        // Record revocation
        passport::record_revocation(&mut passport, &clock, ts::ctx(&mut scenario));
        assert!(passport::revocations_received(&passport) == 1, 1);
        assert!(passport::active_mandate_count(&passport) == 0, 2);

        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G09: Verification tier set by admin
fun test_verification_tier() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    clock::set_for_testing(&mut clock, 1_000_000);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let admin_cap = ts::take_from_sender<AdminCap>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        assert!(passport::verification_tier(&passport) == 0, 0);
        assert!(!passport::verified(&passport), 1);

        passport::set_verification_tier(&admin_cap, &mut passport, 2, &clock);

        assert!(passport::verification_tier(&passport) == 2, 2);
        assert!(passport::verified(&passport), 3);

        // Set back to 0 — unverified
        passport::set_verification_tier(&admin_cap, &mut passport, 0, &clock);
        assert!(passport::verification_tier(&passport) == 0, 4);
        assert!(!passport::verified(&passport), 5);

        ts::return_shared(passport);
        ts::return_to_sender(&scenario, admin_cap);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G10: Score stays 0 until MIN_ACTIONS_FOR_SCORE (10) actions reached
fun test_score_below_min_actions() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);

        // Record 9 actions (below MIN_ACTIONS_FOR_SCORE = 10)
        let mut i = 0u64;
        while (i < 9) {
            passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));
            i = i + 1;
        };

        // Score should still be 0 — not enough actions
        assert!(passport::reputation_score(&passport) == 0, 0);

        // 10th action triggers score computation
        passport::record_action(&mut passport, &mut registry, USER1, PROTOCOL1, 1_000, true, &clock, ts::ctx(&mut scenario));

        // Now score should be > 0 (all successes = 400 accuracy minimum)
        assert!(passport::reputation_score(&passport) > 0, 1);

        ts::return_shared(passport);
        ts::return_shared(registry);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-G13: register_agent public entry point creates passport for sender
fun test_register_agent() {
    let mut scenario = ts::begin(AGENT1);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // AGENT1 calls register_agent
    ts::next_tx(&mut scenario, AGENT1);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        assert!(!passport::has_passport(&registry, AGENT1), 0);
        passport::register_agent(&mut registry, &clock, ts::ctx(&mut scenario));
        assert!(passport::has_passport(&registry, AGENT1), 1);
        ts::return_shared(registry);
    };

    // Calling again is idempotent
    ts::next_tx(&mut scenario, AGENT1);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::register_agent(&mut registry, &clock, ts::ctx(&mut scenario));
        assert!(passport::registry_total_registered(&registry) == 1, 2);
        ts::return_shared(registry);
    };

    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::passport::EPassportNotFound)]
/// EC-G11: get_passport_id for non-existent agent aborts
fun test_passport_not_found() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);

    ts::next_tx(&mut scenario, ADMIN);
    {
        let registry = ts::take_shared<AgentRegistry>(&scenario);
        // This should abort — no passport for AGENT1
        let _id = passport::get_passport_id(&registry, AGENT1);
        ts::return_shared(registry);
    };
    ts::end(scenario);
}

#[test]
/// EC-G12: Mandate count increment/decrement
fun test_mandate_count_operations() {
    let mut scenario = ts::begin(ADMIN);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut registry = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut registry, AGENT1, &clock, ts::ctx(&mut scenario));
        ts::return_shared(registry);
    };

    ts::next_tx(&mut scenario, ADMIN);
    {
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        passport::increment_mandate_count(&mut passport);
        passport::increment_mandate_count(&mut passport);
        assert!(passport::active_mandate_count(&passport) == 2, 0);

        passport::decrement_mandate_count(&mut passport);
        assert!(passport::active_mandate_count(&passport) == 1, 1);

        // Decrement below 0 should clamp at 0
        passport::decrement_mandate_count(&mut passport);
        passport::decrement_mandate_count(&mut passport);
        assert!(passport::active_mandate_count(&passport) == 0, 2);

        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
