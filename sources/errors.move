/// Centralized error codes for the MoveGate protocol.
/// No dependencies. Every error constant is documented with when it fires.
module movegate::errors;

// ═══════════════════════════════════════════════════════════════════
// Category A — Mandate Creation
// ═══════════════════════════════════════════════════════════════════

/// Mandate expires_at is in the past or equal to current timestamp.
const EInvalidExpiry: u64 = 1;

/// Mandate spend_cap is zero — must be >= MIN_SPEND_CAP.
const EInvalidSpendCap: u64 = 2;

/// Mandate daily_limit is less than spend_cap — at least 1 action/epoch must be possible.
const EInvalidDailyLimit: u64 = 3;

/// Agent address is the zero address (0x0).
const EInvalidAgent: u64 = 4;

/// Agent's passport score is below the mandate's min_agent_score requirement.
const EAgentScoreTooLow: u64 = 5;

/// Mandate allowed_protocols list is empty — at least one protocol required.
const EEmptyProtocolList: u64 = 6;

/// Mandate allowed_protocols list exceeds MAX_PROTOCOLS.
const EProtocolListTooLarge: u64 = 7;

/// Payment coin value is below the mandate creation fee.
const EInsufficientFee: u64 = 8;

/// Delegation depth exceeds MAX_DELEGATION_DEPTH.
const EMaxDepthExceeded: u64 = 9;

// ═══════════════════════════════════════════════════════════════════
// Category B — Authorization
// ═══════════════════════════════════════════════════════════════════

/// Transaction sender is not the mandate's designated agent.
const EWrongAgent: u64 = 10;

/// Mandate has passed its expires_at timestamp.
const EExpiredMandate: u64 = 11;

/// Mandate has been revoked by the owner.
const EMandateRevoked: u64 = 12;

/// Requested amount exceeds the mandate's spend_cap.
const EExceedsSpendCap: u64 = 13;

/// Requested amount would push spent_this_epoch over daily_limit.
const EDailyLimitExceeded: u64 = 14;

/// Target protocol address is not in allowed_protocols.
const EProtocolNotAllowed: u64 = 15;

/// Coin type is not in allowed_coin_types.
const ECoinNotAllowed: u64 = 16;

/// Action type is not in allowed_actions.
const EActionNotAllowed: u64 = 17;

/// Requested amount is zero.
const EZeroAmount: u64 = 18;

/// AuthToken mandate_id does not match the expected mandate.
const EMandateIdMismatch: u64 = 19;

// ═══════════════════════════════════════════════════════════════════
// Category C — Revocation
// ═══════════════════════════════════════════════════════════════════

/// Caller is not the mandate owner.
const ENotOwner: u64 = 20;

/// Mandate is already revoked.
const EAlreadyRevoked: u64 = 21;

// ═══════════════════════════════════════════════════════════════════
// Category D — Delegation Chain
// ═══════════════════════════════════════════════════════════════════

/// Child mandate spend_cap exceeds parent's spend_cap.
const EExceedsParentCap: u64 = 22;

/// Child mandate daily_limit exceeds parent's daily_limit.
const EExceedsParentDaily: u64 = 23;

/// Child mandate protocol not present in parent's allowed_protocols.
const EProtocolNotInParent: u64 = 24;

/// Child mandate expires after parent mandate.
const EChildOutlivesParent: u64 = 25;

/// Delegation would create a cycle.
const ECyclicDelegation: u64 = 26;

// ═══════════════════════════════════════════════════════════════════
// Category E — Treasury
// ═══════════════════════════════════════════════════════════════════

/// Treasury balance is zero — nothing to withdraw.
const EZeroBalance: u64 = 27;

/// Caller does not hold AdminCap.
const ENotAdmin: u64 = 28;

/// Fee BPS exceeds MAX_FEE_BPS ceiling.
const EFeeTooHigh: u64 = 29;

/// Fee calculation would overflow u64 (should not happen with u128 intermediary).
const EFeeOverflow: u64 = 30;

// ═══════════════════════════════════════════════════════════════════
// Category F — Upgrade
// ═══════════════════════════════════════════════════════════════════

/// Reserved for upgrade-related errors.
const EUpgradeNotAllowed: u64 = 31;

// ═══════════════════════════════════════════════════════════════════
// Category G — Passport
// ═══════════════════════════════════════════════════════════════════

/// Passport already exists for this agent address.
const EPassportAlreadyExists: u64 = 32;

/// Passport not found for this agent address.
const EPassportNotFound: u64 = 33;

/// Score update attempted before cooldown period elapsed.
const EScoreCooldownActive: u64 = 34;

/// Amount in AuthToken does not match the expected amount at consumption.
const EAmountMismatch: u64 = 35;

// ═══════════════════════════════════════════════════════════════════
// Public accessor functions — modules abort with these codes
// ═══════════════════════════════════════════════════════════════════

public fun invalid_expiry(): u64 { EInvalidExpiry }
public fun invalid_spend_cap(): u64 { EInvalidSpendCap }
public fun invalid_daily_limit(): u64 { EInvalidDailyLimit }
public fun invalid_agent(): u64 { EInvalidAgent }
public fun agent_score_too_low(): u64 { EAgentScoreTooLow }
public fun empty_protocol_list(): u64 { EEmptyProtocolList }
public fun protocol_list_too_large(): u64 { EProtocolListTooLarge }
public fun insufficient_fee(): u64 { EInsufficientFee }
public fun max_depth_exceeded(): u64 { EMaxDepthExceeded }
public fun wrong_agent(): u64 { EWrongAgent }
public fun expired_mandate(): u64 { EExpiredMandate }
public fun mandate_revoked(): u64 { EMandateRevoked }
public fun exceeds_spend_cap(): u64 { EExceedsSpendCap }
public fun daily_limit_exceeded(): u64 { EDailyLimitExceeded }
public fun protocol_not_allowed(): u64 { EProtocolNotAllowed }
public fun coin_not_allowed(): u64 { ECoinNotAllowed }
public fun action_not_allowed(): u64 { EActionNotAllowed }
public fun zero_amount(): u64 { EZeroAmount }
public fun mandate_id_mismatch(): u64 { EMandateIdMismatch }
public fun not_owner(): u64 { ENotOwner }
public fun already_revoked(): u64 { EAlreadyRevoked }
public fun exceeds_parent_cap(): u64 { EExceedsParentCap }
public fun exceeds_parent_daily(): u64 { EExceedsParentDaily }
public fun protocol_not_in_parent(): u64 { EProtocolNotInParent }
public fun child_outlives_parent(): u64 { EChildOutlivesParent }
public fun cyclic_delegation(): u64 { ECyclicDelegation }
public fun zero_balance(): u64 { EZeroBalance }
public fun not_admin(): u64 { ENotAdmin }
public fun fee_too_high(): u64 { EFeeTooHigh }
public fun fee_overflow(): u64 { EFeeOverflow }
public fun upgrade_not_allowed(): u64 { EUpgradeNotAllowed }
public fun passport_already_exists(): u64 { EPassportAlreadyExists }
public fun passport_not_found(): u64 { EPassportNotFound }
public fun score_cooldown_active(): u64 { EScoreCooldownActive }
public fun amount_mismatch(): u64 { EAmountMismatch }
