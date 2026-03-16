#[test_only]
module movegate::delegation_tests;

use sui::test_scenario::{Self as ts};
use sui::coin;
use sui::sui::SUI;
use sui::clock::{Self, Clock};
use std::type_name;
use movegate::treasury::{Self, FeeConfig, ProtocolTreasury};
use movegate::passport::{Self, AgentRegistry, AgentPassport};
use movegate::mandate::{Self, MandateRegistry};

const OWNER: address = @0xA1;
const AGENT: address = @0xB2;
const SUB_AGENT: address = @0xB3;
const PROTOCOL: address = @0xC3;
const PROTOCOL2: address = @0xC4;

fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, OWNER);
    {
        treasury::init_for_testing(ts::ctx(scenario));
        passport::init_for_testing(ts::ctx(scenario));
        mandate::init_for_testing(ts::ctx(scenario));
    };
}

/// Create a parent mandate owned by OWNER, agent = AGENT
fun create_parent_mandate(scenario: &mut ts::Scenario, clock: &Clock) {
    // ensure_passport must be in a prior tx so the shared AgentPassport is available next tx
    ts::next_tx(scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(scenario);
        passport::ensure_passport(&mut ar, AGENT, clock, ts::ctx(scenario));
        ts::return_shared(ar);
    };

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
            AGENT,
            100_000,   // spend_cap
            1_000_000, // daily_limit
            vector[PROTOCOL, PROTOCOL2],
            vector::empty<type_name::TypeName>(),
            vector::empty<u8>(),
            clock.timestamp_ms() + 86_400_000, // 1 day
            option::none(),
            &mut payment, clock, ts::ctx(scenario),
        );

        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
}

// ═══════════════════════════════════════════════════════════════════
// Category D — Delegation Chain Edge Cases
// ═══════════════════════════════════════════════════════════════════

#[test]
/// EC-D01: Valid delegation with tighter limits
fun test_valid_delegation() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr,
            SUB_AGENT,
            50_000,   // <= parent 100_000
            500_000,  // <= parent 1_000_000
            vector[PROTOCOL], // subset of parent
            clock.timestamp_ms() + 43_200_000, // 12h < parent's 24h
            &clock, ts::ctx(&mut scenario),
        );

        assert!(mandate::mandate_agent(&child) == SUB_AGENT, 0);
        assert!(mandate::mandate_spend_cap(&child) == 50_000, 1);
        assert!(mandate::mandate_daily_limit(&child) == 500_000, 2);
        assert!(mandate::mandate_current_depth(&child) == 1, 3);
        assert!(option::is_some(mandate::mandate_parent_id(&child)), 4);

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EExceedsParentCap)]
/// EC-D02: Child spend_cap > parent spend_cap
fun test_child_exceeds_parent_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT,
            200_000,   // > parent's 100_000
            1_000_000,
            vector[PROTOCOL],
            clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EExceedsParentDaily)]
/// EC-D03: Child daily_limit > parent daily_limit
fun test_child_exceeds_parent_daily() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT,
            50_000,
            2_000_000, // > parent's 1_000_000
            vector[PROTOCOL],
            clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EProtocolNotInParent)]
/// EC-D04: Child protocol not in parent's whitelist
fun test_child_protocol_not_in_parent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT,
            50_000, 500_000,
            vector[@0xDEAD], // not in parent's protocols
            clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EChildOutlivesParent)]
/// EC-D05: Child expires after parent
fun test_child_outlives_parent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT,
            50_000, 500_000,
            vector[PROTOCOL],
            clock.timestamp_ms() + 100_000_000, // > parent's 86_400_000
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EMaxDepthExceeded)]
/// EC-D06: Delegation chain exceeds MAX_DELEGATION_DEPTH
fun test_max_depth_exceeded() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    // Create a chain of delegations up to depth 5 (max), then try depth 6
    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        // Depth 1
        let child1 = mandate::delegate_mandate(
            &parent, &mut mr, SUB_AGENT, 50_000, 500_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        // Depth 2
        let child2 = mandate::delegate_mandate(
            &child1, &mut mr, SUB_AGENT, 40_000, 400_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        // Depth 3
        let child3 = mandate::delegate_mandate(
            &child2, &mut mr, SUB_AGENT, 30_000, 300_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        // Depth 4
        let child4 = mandate::delegate_mandate(
            &child3, &mut mr, SUB_AGENT, 20_000, 200_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        // Depth 5
        let child5 = mandate::delegate_mandate(
            &child4, &mut mr, SUB_AGENT, 10_000, 100_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        // Depth 6 — should abort (max depth = 5)
        let child6 = mandate::delegate_mandate(
            &child5, &mut mr, SUB_AGENT, 5_000, 50_000,
            vector[PROTOCOL], clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child6);
        mandate::destroy_mandate_for_testing(child5);
        mandate::destroy_mandate_for_testing(child4);
        mandate::destroy_mandate_for_testing(child3);
        mandate::destroy_mandate_for_testing(child2);
        mandate::destroy_mandate_for_testing(child1);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EMandateRevoked)]
/// EC-D07: Cannot delegate from a revoked parent
fun test_delegate_revoked_parent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    // Create passport for agent (required by revoke)
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Revoke parent
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<passport::AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut parent, &mut mr, &mut passport, 0, &clock, ts::ctx(&mut scenario));

        ts::return_to_sender(&scenario, parent);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };

    // Try to delegate from revoked parent
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

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidAgent)]
/// EC-D08: Cannot delegate to zero agent
fun test_delegate_zero_agent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);
    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_parent_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let parent = ts::take_from_sender<mandate::Mandate>(&scenario);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);

        let child = mandate::delegate_mandate(
            &parent, &mut mr, @0x0, // zero agent
            50_000, 500_000,
            vector[PROTOCOL],
            clock.timestamp_ms() + 43_200_000,
            &clock, ts::ctx(&mut scenario),
        );

        mandate::destroy_mandate_for_testing(child);
        transfer::public_transfer(parent, OWNER);
        ts::return_shared(mr);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
