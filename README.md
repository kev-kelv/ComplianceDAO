# ComplianceDAO

**Version:** 1.0.0  
**Language:** Clarity (Stacks blockchain)

A decentralised governance contract for adopting and managing compliance rules through weighted stakeholder voting. Proposers lock an escrow deposit when submitting a rule — returned on rejection or successful implementation, forfeited to the DAO treasury if the implementation deadline is missed. This accountability mechanism ensures that passed rules are actually followed through on.

---

## Table of Contents

- [Overview](#overview)
- [How It Works](#how-it-works)
- [Stakeholders & Voting Power](#stakeholders--voting-power)
- [Escrow Mechanic](#escrow-mechanic)
- [Proposal Lifecycle](#proposal-lifecycle)
- [Governance Parameters](#governance-parameters)
- [Public Functions](#public-functions)
- [Read-Only Functions](#read-only-functions)
- [Error Codes](#error-codes)
- [Constants Reference](#constants-reference)

---

## Overview

ComplianceDAO is built around three core ideas:

1. **Stake-weighted participation.** Voting power is proportional to the STX staked at registration. More skin in the game means more say.
2. **Escrow accountability.** Proposers must lock 5 STX when submitting a rule. This deposit is returned for rejected proposals and successful implementations, but forfeited to the treasury if a passed rule is never implemented.
3. **Transparent, permissionless finalisation.** Anyone can finalise or expire a proposal once the relevant deadline has passed — no privileged administrator required.

---

## How It Works

```
1. Register as stakeholder (lock STX stake)
         ↓
2. Submit a compliance rule proposal (lock 5 STX escrow)
         ↓
3. Stakeholders vote FOR or AGAINST over ~10 days
         ↓
4. Anyone calls finalize-proposal after voting closes
   ├─ REJECTED → escrow returned to proposer immediately
   └─ PASSED   → escrow held; proposer has ~30 days to implement
                        ↓
              5a. implement-rule (within deadline)
                  → status: IMPLEMENTED, escrow returned
              5b. expire-unimplemented-proposal (after deadline)
                  → status: EXPIRED, escrow forfeited to treasury
```

---

## Stakeholders & Voting Power

Any principal may register as a stakeholder by locking at least 1 STX (1,000,000 microSTX) in the contract. Voting power is assigned linearly: **1 unit per 1 STX staked**.

Stake is fully returned upon unregistration. Past votes are not reversed, and historical participation is preserved on-chain. Stakeholders may unregister at any time, but their voting power is removed from the aggregate total immediately, which affects quorum calculations for future proposals.

---

## Escrow Mechanic

Every proposal requires a 5 STX (5,000,000 microSTX) escrow deposit from the proposer.

| Outcome | Escrow fate |
|---------|-------------|
| Proposal **rejected** | Returned to proposer at finalisation |
| Proposal **passed + implemented** within deadline | Returned to proposer via `implement-rule` |
| Proposal **passed + deadline missed** | Forfeited to DAO treasury via `expire-unimplemented-proposal` |

The treasury balance is tracked on-chain and queryable via `get-treasury-balance`. Forfeited funds remain in the contract.

---

## Proposal Lifecycle

| Status | Constant | Value | Meaning |
|--------|----------|-------|---------|
| Active | `STATUS-ACTIVE` | `u1` | Voting is open |
| Passed | `STATUS-PASSED` | `u2` | Quorum and approval threshold met |
| Rejected | `STATUS-REJECTED` | `u3` | Quorum or approval threshold not met |
| Implemented | `STATUS-IMPLEMENTED` | `u4` | Rule implemented within deadline; escrow returned |
| Expired | `STATUS-EXPIRED` | `u5` | Deadline missed; escrow forfeited |

A proposal passes if **both** conditions hold after the voting window closes:

1. `total-participation / total-voting-power >= 20%` (quorum)
2. `votes-for / total-votes >= 51%` (approval majority)

---

## Governance Parameters

| Parameter | Value | Description |
|-----------|-------|-------------|
| `VOTING-PERIOD` | `u1440` | Blocks the vote stays open (~10 days) |
| `IMPLEMENTATION-WINDOW` | `u4320` | Blocks after voting closes to implement (~30 days) |
| `QUORUM-PERCENTAGE` | `u20` | Minimum % of total voting power that must participate |
| `APPROVAL-PERCENTAGE` | `u51` | Minimum % of cast votes that must be FOR to pass |
| `MIN-STAKE` | `u1000000` | Minimum STX stake to register (1 STX in microSTX) |
| `PROPOSAL-ESCROW-AMOUNT` | `u5000000` | Escrow required per proposal (5 STX in microSTX) |

All parameters are hard-coded constants and cannot be changed without redeployment. Use `get-governance-params` to query them all at once.

---

## Public Functions

### Stakeholder Management

#### `register-stakeholder (stake-amount uint)`
Registers the caller as a stakeholder by transferring `stake-amount` microSTX into the contract. Stake must be at least `MIN-STAKE` and must yield at least one unit of voting power. Returns the assigned voting power on success.

#### `unregister-stakeholder`
Removes the caller from the stakeholder registry and returns their full STX stake. Historical votes and proposals remain on-chain. Reduces the aggregate voting power immediately.

---

### Proposal Lifecycle

#### `submit-proposal (title string-ascii-128) (description string-utf8-1024) (rule-text string-utf8-2048)`
Submits a new compliance rule proposal. The caller must be a registered stakeholder. Transfers `PROPOSAL-ESCROW-AMOUNT` from the caller into the contract. Voting opens immediately and runs for `VOTING-PERIOD` blocks. Returns the new proposal ID.

- `title` — Short label up to 128 ASCII characters.
- `description` — Plain-language summary up to 1024 UTF-8 characters.
- `rule-text` — Full rule body up to 2048 UTF-8 characters.

#### `vote-on-proposal (proposal-id uint) (vote-for bool)`
Casts a weighted vote on an active proposal. The caller must be a registered stakeholder. Each stakeholder may vote only once per proposal. Vote weight equals the caller's current voting-power units. Passing `true` votes FOR; `false` votes AGAINST. Returns the boolean vote cast.

#### `finalize-proposal (proposal-id uint)`
Resolves a proposal once its voting window has closed. Permissionless — any principal may call this. Evaluates quorum and approval conditions and transitions the proposal to `STATUS-PASSED` or `STATUS-REJECTED`. Returns the escrow to the proposer immediately on rejection. Returns the resulting status code.

#### `implement-rule (proposal-id uint)`
Marks a passed proposal as implemented and returns the escrow to the original proposer. Only the proposer may call this, and only within the `implementation-deadline`. Returns `true` on success.

#### `expire-unimplemented-proposal (proposal-id uint)`
Expires a passed proposal whose implementation deadline has been missed. Permissionless — any principal may call this after the deadline. Forfeits the escrow to the DAO treasury and transitions the proposal to `STATUS-EXPIRED`. Returns `true` on success.

---

## Read-Only Functions

| Function | Returns | Description |
|----------|---------|-------------|
| `get-proposal (proposal-id uint)` | `(optional proposal)` | Full proposal record |
| `get-stakeholder (addr principal)` | `(optional stakeholder)` | Full stakeholder record including stake and voting power |
| `get-vote (proposal-id uint) (voter principal)` | `(optional vote)` | A stakeholder's vote on a specific proposal |
| `get-proposal-count` | `uint` | Total proposals ever submitted |
| `get-total-voting-power` | `uint` | Aggregate voting power of all active stakeholders |
| `get-treasury-balance` | `uint` | Accumulated forfeited escrow in the DAO treasury |
| `get-contract-stx-balance` | `uint` | Live STX balance of the contract (stake + escrow + treasury) |
| `check-quorum (proposal-id uint)` | `bool` | Whether the proposal currently meets the quorum threshold |
| `check-approval (proposal-id uint)` | `bool` | Whether the proposal currently meets the approval threshold |
| `is-registered (addr principal)` | `bool` | Whether an address is a registered stakeholder |
| `get-governance-params` | `tuple` | All governance constants in a single response |

---

## Error Codes

| Code | Constant | When it's thrown |
|------|----------|-----------------|
| `u101` | `ERR-ALREADY-REGISTERED` | Principal is already a registered stakeholder |
| `u102` | `ERR-NOT-REGISTERED` | Caller is not a registered stakeholder |
| `u103` | `ERR-INSUFFICIENT-STAKE` | Stake amount is below `MIN-STAKE` |
| `u104` | `ERR-INVALID-PROPOSAL` | Proposal ID does not exist |
| `u105` | `ERR-VOTING-CLOSED` | Voting window has ended or proposal is not active |
| `u106` | `ERR-VOTING-ACTIVE` | Trying to finalise before the voting window has closed |
| `u107` | `ERR-ALREADY-VOTED` | Caller has already voted on this proposal |
| `u108` | `ERR-PROPOSAL-NOT-PASSED` | Proposal has not reached `STATUS-PASSED` |
| `u109` | `ERR-ALREADY-IMPLEMENTED` | Proposal escrow has already been claimed |
| `u110` | `ERR-ALREADY-FINALIZED` | Proposal is no longer in `STATUS-ACTIVE` |
| `u112` | `ERR-DEADLINE-PASSED` | Implementation deadline has already passed |
| `u113` | `ERR-NOT-PROPOSER` | Caller is not the original proposer |
| `u114` | `ERR-DEADLINE-NOT-REACHED` | Implementation deadline has not yet passed |
| `u115` | `ERR-ZERO-VOTING-POWER` | Stake amount too low to yield any voting power |

---

## Constants Reference

```clarity
;; Governance Parameters
VOTING-PERIOD            u1440     ;; ~10 days at ~144 blocks/day
IMPLEMENTATION-WINDOW    u4320     ;; ~30 days after voting closes
QUORUM-PERCENTAGE        u20       ;; 20% of total voting power must participate
APPROVAL-PERCENTAGE      u51       ;; 51% of cast votes must be FOR
MIN-STAKE                u1000000  ;; 1 STX minimum stake (microSTX)
PROPOSAL-ESCROW-AMOUNT   u5000000  ;; 5 STX escrow per proposal (microSTX)

;; Proposal Status Codes
STATUS-ACTIVE            u1
STATUS-PASSED            u2
STATUS-REJECTED          u3
STATUS-IMPLEMENTED       u4
STATUS-EXPIRED           u5
```