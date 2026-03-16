#[test_only]
module movegate::mandate_tests;

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
const PROTOCOL: address = @0xC3;
const BAD_AGENT: address = @0xD4;
const BAD_PROTOCOL: address = @0xE5;

/// Helper: initialize all shared objects for testing
fun setup(scenario: &mut ts::Scenario) {
    ts::next_tx(scenario, OWNER);
    {
        treasury::init_for_testing(ts::ctx(scenario));
        passport::init_for_testing(ts::ctx(scenario));
        mandate::init_for_testing(ts::ctx(scenario));
    };
}

/// Helper: create a standard valid mandate and transfer to OWNER
fun create_standard_mandate(scenario: &mut ts::Scenario, clock: &Clock) {
    // Ensure passport for AGENT in its own tx so it's available in the next
    ts::next_tx(scenario, OWNER);
    {
        let mut agent_registry = ts::take_shared<AgentRegistry>(scenario);
        passport::ensure_passport(&mut agent_registry, AGENT, clock, ts::ctx(scenario));
        ts::return_shared(agent_registry);
    };

    ts::next_tx(scenario, OWNER);
    {
        let mut mandate_registry = ts::take_shared<MandateRegistry>(scenario);
        let mut agent_registry = ts::take_shared<AgentRegistry>(scenario);
        let mut passport = ts::take_shared<AgentPassport>(scenario);
        let mut treasury = ts::take_shared<ProtocolTreasury>(scenario);
        let fee_config = ts::take_shared<FeeConfig>(scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(scenario));

        let mandate = mandate::create_mandate(
            &mut mandate_registry,
            &mut agent_registry,
            &mut passport,
            &mut treasury,
            &fee_config,
            AGENT,
            100_000, // spend_cap
            1_000_000, // daily_limit
            vector[PROTOCOL],
            vector::empty<type_name::TypeName>(), // all coin types
            vector::empty<u8>(), // all action types
            clock.timestamp_ms() + 86_400_000, // expires in 1 day
            option::none(), // no min score
            &mut payment,
            clock,
            ts::ctx(scenario),
        );

        transfer::public_transfer(mandate, OWNER);
        coin::burn_for_testing(payment);
        ts::return_shared(mandate_registry);
        ts::return_shared(agent_registry);
        ts::return_shared(passport);
        ts::return_shared(treasury);
        ts::return_shared(fee_config);
    };
}

// ═══════════════════════════════════════════════════════════════════
// Category A — Mandate Creation (15 edge cases)
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidExpiry)]
/// EC-A01: expires_at in the past
fun test_create_expired_mandate() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    clock::set_for_testing(&mut clock, 1000);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 1_000, 1_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            500, // expires in the past (current = 1000)
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidExpiry)]
/// EC-A02: expires_at == current timestamp
fun test_create_expiry_now() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    clock::set_for_testing(&mut clock, 1000);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);
        let mut tr = ts::take_shared<ProtocolTreasury>(&scenario);
        let fc = ts::take_shared<FeeConfig>(&scenario);

        let mut payment = coin::mint_for_testing<SUI>(100_000_000, ts::ctx(&mut scenario));

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 1_000, 1_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            1000, // equals current
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidSpendCap)]
/// EC-A03: spend_cap == 0
fun test_zero_spend_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 0, 0,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidDailyLimit)]
/// EC-A04: daily_limit < spend_cap
fun test_daily_less_than_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 10_000, 5_000, // daily < cap
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
/// EC-A05: daily_limit == spend_cap should pass (1 action/epoch valid)
fun test_daily_equals_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 10_000, 10_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        assert!(mandate::mandate_spend_cap(&m) == 10_000, 0);
        assert!(mandate::mandate_daily_limit(&m) == 10_000, 1);

        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EInvalidAgent)]
/// EC-A06: agent == 0x0
fun test_zero_agent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT (need a valid passport even though test will abort)
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
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, @0x0, 1_000, 1_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EEmptyProtocolList)]
/// EC-A09: empty allowed_protocols
fun test_empty_protocols() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 1_000, 1_000,
            vector::empty<address>(), // empty!
            vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EProtocolListTooLarge)]
/// EC-A10: 21 protocols in list exceeds MAX_PROTOCOLS (20)
fun test_too_many_protocols() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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

        // Build vector with 21 addresses
        let mut protos = vector::empty<address>();
        let mut i = 0u64;
        while (i < 21) {
            // Create unique addresses by using i as seed
            vector::push_back(&mut protos, @0x100);
            i = i + 1;
        };

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 1_000, 1_000,
            protos, vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::treasury::EInsufficientFee)]
/// EC-A11: payment below creation fee
fun test_insufficient_fee() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for AGENT
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

        let mut payment = coin::mint_for_testing<SUI>(1, ts::ctx(&mut scenario)); // 1 MIST only

        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, AGENT, 1_000, 1_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

#[test]
/// EC-A15: agent == owner (self-delegation allowed)
fun test_self_delegation() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));

    // Ensure passport for OWNER (who is also the agent here)
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, OWNER, &clock, ts::ctx(&mut scenario));
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

        // OWNER is both owner and agent
        let m = mandate::create_mandate(
            &mut mr, &mut ar, &mut passport, &mut tr, &fc, OWNER, 1_000, 1_000,
            vector[PROTOCOL], vector::empty(), vector::empty(),
            86_400_000,
            option::none(), &mut payment, &clock, ts::ctx(&mut scenario),
        );
        assert!(mandate::mandate_owner(&m) == OWNER, 0);
        assert!(mandate::mandate_agent(&m) == OWNER, 1);

        transfer::public_transfer(m, OWNER);
        coin::burn_for_testing(payment);
        clock::destroy_for_testing(clock);
        ts::return_shared(mr); ts::return_shared(ar); ts::return_shared(passport); ts::return_shared(tr); ts::return_shared(fc);
    };
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// Category B — Authorization Edge Cases
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::EWrongAgent)]
/// EC-B01: Wrong agent address tries to authorize
fun test_wrong_agent() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    // Ensure passport exists for BAD_AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, BAD_AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // BAD_AGENT tries to use AGENT's mandate
    ts::next_tx(&mut scenario, BAD_AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );

        // Won't reach here
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EExpiredMandate)]
/// EC-B02: Mandate expired 1ms ago
fun test_expired_by_1ms() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let mut clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    // Ensure passport for AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Advance clock past expiry
    clock::set_for_testing(&mut clock, 86_400_001); // 1ms past expiry

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EMandateRevoked)]
/// EC-B03: Mandate is revoked
fun test_revoked_mandate() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    // Ensure passport
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Owner revokes
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 0, &clock, ts::ctx(&mut scenario));

        ts::return_to_address(OWNER, mandate);
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
            PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EExceedsSpendCap)]
/// EC-B04: amount > spend_cap
fun test_exceeds_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 200_000, 0, &clock, ts::ctx(&mut scenario), // > 100_000 cap
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 200_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EProtocolNotAllowed)]
/// EC-B08: Protocol not whitelisted
fun test_bad_protocol() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            BAD_PROTOCOL, 1_000, 0, &clock, ts::ctx(&mut scenario),
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, BAD_PROTOCOL, 1_000);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EZeroAmount)]
/// EC-B11: amount == 0
fun test_zero_amount() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 0, 0, &clock, ts::ctx(&mut scenario),
        );

        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 0);
        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// EC-B05: amount == spend_cap should pass
fun test_at_cap() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 100_000, 0, &clock, ts::ctx(&mut scenario),
        );

        assert!(mandate::auth_token_amount(&token) == 100_000, 0);
        let (_, _, _, _, _, _, _, _) = mandate::consume_auth_token(token, PROTOCOL, 100_000);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

// ═══════════════════════════════════════════════════════════════════
// Category C — Revocation
// ═══════════════════════════════════════════════════════════════════

#[test]
#[expected_failure(abort_code = movegate::mandate::ENotOwner)]
/// EC-C01: Non-owner tries to revoke
fun test_revoke_not_owner() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // Agent (not owner) tries to revoke
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 0, &clock, ts::ctx(&mut scenario));

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
#[expected_failure(abort_code = movegate::mandate::EAlreadyRevoked)]
/// EC-C02: Double revoke
fun test_double_revoke() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        ts::return_shared(ar);
    };

    // First revoke
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 0, &clock, ts::ctx(&mut scenario));

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };

    // Second revoke — should abort
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut mr = ts::take_shared<MandateRegistry>(&scenario);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        mandate::revoke_mandate(&mut mandate, &mut mr, &mut passport, 0, &clock, ts::ctx(&mut scenario));

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(mr);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}

#[test]
/// Valid mandate creation and successful authorization flow
fun test_full_happy_path() {
    let mut scenario = ts::begin(OWNER);
    setup(&mut scenario);

    let clock = clock::create_for_testing(ts::ctx(&mut scenario));
    create_standard_mandate(&mut scenario, &clock);

    // Ensure passport for AGENT
    ts::next_tx(&mut scenario, OWNER);
    {
        let mut ar = ts::take_shared<AgentRegistry>(&scenario);
        passport::ensure_passport(&mut ar, AGENT, &clock, ts::ctx(&mut scenario));
        assert!(passport::has_passport(&ar, AGENT), 0);
        ts::return_shared(ar);
    };

    // Agent authorizes action
    ts::next_tx(&mut scenario, AGENT);
    {
        let mut mandate = ts::take_from_address<mandate::Mandate>(&scenario, OWNER);
        let mut passport = ts::take_shared<AgentPassport>(&scenario);

        let token = mandate::authorize_action<SUI>(
            &mut mandate, &mut passport,
            PROTOCOL, 50_000, 0, &clock, ts::ctx(&mut scenario),
        );

        // Verify token fields
        assert!(mandate::auth_token_agent(&token) == AGENT, 1);
        assert!(mandate::auth_token_protocol(&token) == PROTOCOL, 2);
        assert!(mandate::auth_token_amount(&token) == 50_000, 3);

        // Consume token (as protocol would)
        let (mid, agent, proto, _ct, amt, _at, _ep, _sc) =
            mandate::consume_auth_token(token, PROTOCOL, 50_000);

        assert!(agent == AGENT, 4);
        assert!(proto == PROTOCOL, 5);
        assert!(amt == 50_000, 6);
        let _ = mid;

        // Verify mandate state updated
        assert!(mandate::mandate_spent_this_epoch(&mandate) == 50_000, 7);
        assert!(mandate::mandate_total_actions(&mandate) == 1, 8);

        ts::return_to_address(OWNER, mandate);
        ts::return_shared(passport);
    };
    clock::destroy_for_testing(clock);
    ts::end(scenario);
}
