;; title: ComplianceDAO
;; version: 1.0.0
;; summary: Transparent rule adoption governance with stakeholder participation and escrow-based implementation mechanics
;; description:
;;   ComplianceDAO enables decentralised governance of compliance rules through weighted stakeholder voting.
;;   Proposers lock an escrow deposit when submitting a rule; that deposit is returned on rejection or
;;   successful implementation, and forfeited to the DAO treasury if the implementation deadline is missed.

;; ============================================================
;; CONSTANTS
;; ============================================================

;; --- Error Codes ---
(define-constant ERR-ALREADY-REGISTERED    (err u101))
(define-constant ERR-NOT-REGISTERED        (err u102))
(define-constant ERR-INSUFFICIENT-STAKE    (err u103))
(define-constant ERR-INVALID-PROPOSAL      (err u104))
(define-constant ERR-VOTING-CLOSED         (err u105))
(define-constant ERR-VOTING-ACTIVE         (err u106))
(define-constant ERR-ALREADY-VOTED         (err u107))
(define-constant ERR-PROPOSAL-NOT-PASSED   (err u108))
(define-constant ERR-ALREADY-IMPLEMENTED   (err u109))
(define-constant ERR-ALREADY-FINALIZED     (err u110))
(define-constant ERR-DEADLINE-PASSED       (err u112))
(define-constant ERR-NOT-PROPOSER          (err u113))
(define-constant ERR-DEADLINE-NOT-REACHED  (err u114))
(define-constant ERR-ZERO-VOTING-POWER     (err u115))

;; --- Governance Parameters ---
;; Stacks produces ~144 blocks/day; adjust constants to match desired real-world windows.
(define-constant VOTING-PERIOD             u1440)   ;; ~10 days of voting
(define-constant IMPLEMENTATION-WINDOW    u4320)   ;; ~30 days to implement after vote closes
(define-constant QUORUM-PERCENTAGE        u20)     ;; 20 % of total voting power must participate
(define-constant APPROVAL-PERCENTAGE      u51)     ;; 51 % of cast votes must be FOR to pass
(define-constant MIN-STAKE                u1000000) ;; 1 STX minimum stake (in microSTX)
(define-constant PROPOSAL-ESCROW-AMOUNT   u5000000) ;; 5 STX escrow per proposal (in microSTX)

;; --- Proposal Status Codes ---
(define-constant STATUS-ACTIVE      u1)
(define-constant STATUS-PASSED      u2)
(define-constant STATUS-REJECTED    u3)
(define-constant STATUS-IMPLEMENTED u4)
(define-constant STATUS-EXPIRED     u5)

;; ============================================================
;; DATA VARS
;; ============================================================

(define-data-var proposal-count    uint u0)
(define-data-var total-voting-power uint u0)
;; Accumulates forfeited escrow from proposals that missed the implementation deadline.
(define-data-var treasury-balance  uint u0)

;; ============================================================
;; DATA MAPS
;; ============================================================

;; Registered DAO participants and their stake information.
(define-map stakeholders
  principal
  {
    stake:               uint,
    voting-power:        uint,
    registered-at:       uint,
    proposals-submitted: uint,
    proposals-voted:     uint
  }
)

;; Compliance rule proposals.
(define-map proposals
  uint ;; proposal-id
  {
    id:                      uint,
    proposer:                principal,
    title:                   (string-ascii 128),
    description:             (string-utf8 1024),
    rule-text:               (string-utf8 2048),
    votes-for:               uint,
    votes-against:           uint,
    total-participation:     uint,
    status:                  uint,
    escrow-amount:           uint,
    escrow-claimed:          bool,
    start-block:             uint,
    end-block:               uint,
    implementation-deadline: uint,
    finalized-at:            uint
  }
)

;; Individual vote records keyed by (proposal-id, voter).
(define-map votes
  { proposal-id: uint, voter: principal }
  {
    vote-for: bool,
    weight:   uint,
    cast-at:  uint
  }
)

;; ============================================================
;; PRIVATE HELPER FUNCTIONS
;; ============================================================

;; Returns true if the principal has a stakeholder record.
(define-private (is-stakeholder (addr principal))
  (is-some (map-get? stakeholders addr))
)

;; Converts a raw STX stake amount to voting-power units (1 unit per MIN-STAKE).
(define-private (calculate-voting-power (stake uint))
  (/ stake MIN-STAKE)
)

;; Returns true when the participating voting-power meets the quorum threshold.
(define-private (quorum-reached (participation uint) (total-power uint))
  (if (is-eq total-power u0)
    false
    (>= (* participation u100) (* total-power QUORUM-PERCENTAGE))
  )
)

;; Returns true when the FOR votes meet the approval threshold.
(define-private (approval-met (for-votes uint) (total-votes uint))
  (if (is-eq total-votes u0)
    false
    (>= (* for-votes u100) (* total-votes APPROVAL-PERCENTAGE))
  )
)

;; ============================================================
;; PUBLIC FUNCTIONS
;; ============================================================

;; ---------------------
;; Stakeholder Management
;; ---------------------

;; Register as a stakeholder by locking STX as stake.
;; Voting power scales linearly: 1 unit per 1 STX staked (above the minimum).
(define-public (register-stakeholder (stake-amount uint))
  (let (
    (caller tx-sender)
    (vp     (calculate-voting-power stake-amount))
  )
    (asserts! (not (is-stakeholder caller)) ERR-ALREADY-REGISTERED)
    (asserts! (>= stake-amount MIN-STAKE)   ERR-INSUFFICIENT-STAKE)
    (asserts! (> vp u0)                    ERR-ZERO-VOTING-POWER)

    ;; Lock the stake inside the contract.
    (try! (stx-transfer? stake-amount caller (as-contract tx-sender)))

    (map-set stakeholders caller {
      stake:               stake-amount,
      voting-power:        vp,
      registered-at:       stacks-block-height,
      proposals-submitted: u0,
      proposals-voted:     u0
    })

    (var-set total-voting-power (+ (var-get total-voting-power) vp))

    (ok vp)
  )
)

;; Unregister and reclaim the full STX stake.
;; Existing votes and proposals remain on-chain; past voting power used is not reversed.
(define-public (unregister-stakeholder)
  (let (
    (caller     tx-sender)
    (stakeholder (unwrap! (map-get? stakeholders caller) ERR-NOT-REGISTERED))
    (stake      (get stake        stakeholder))
    (vp         (get voting-power stakeholder))
  )
    (try! (as-contract (stx-transfer? stake tx-sender caller)))

    (map-delete stakeholders caller)
    (var-set total-voting-power (- (var-get total-voting-power) vp))

    (ok stake)
  )
)

;; ---------------------
;; Proposal Lifecycle
;; ---------------------

;; Submit a new compliance rule proposal.
;; The caller must be a registered stakeholder and must lock PROPOSAL-ESCROW-AMOUNT STX.
;; Escrow mechanic:
;;   - REJECTED  : escrow is returned when the proposal is finalised.
;;   - PASSED + implemented within deadline : escrow returned to proposer.
;;   - PASSED + deadline missed             : escrow forfeited to the DAO treasury.
(define-public (submit-proposal
    (title       (string-ascii 128))
    (description (string-utf8 1024))
    (rule-text   (string-utf8 2048)))
  (let (
    (caller      tx-sender)
    (stakeholder (unwrap! (map-get? stakeholders caller) ERR-NOT-REGISTERED))
    (new-id      (+ (var-get proposal-count) u1))
    (end-block   (+ stacks-block-height VOTING-PERIOD))
    (impl-dl     (+ stacks-block-height VOTING-PERIOD IMPLEMENTATION-WINDOW))
  )
    ;; Collect escrow commitment from the proposer.
    (try! (stx-transfer? PROPOSAL-ESCROW-AMOUNT caller (as-contract tx-sender)))

    (map-set proposals new-id {
      id:                      new-id,
      proposer:                caller,
      title:                   title,
      description:             description,
      rule-text:               rule-text,
      votes-for:               u0,
      votes-against:           u0,
      total-participation:     u0,
      status:                  STATUS-ACTIVE,
      escrow-amount:           PROPOSAL-ESCROW-AMOUNT,
      escrow-claimed:          false,
      start-block:             stacks-block-height,
      end-block:               end-block,
      implementation-deadline: impl-dl,
      finalized-at:            u0
    })

    (var-set proposal-count new-id)

    ;; Track submissions per stakeholder.
    (map-set stakeholders caller
      (merge stakeholder { proposals-submitted: (+ (get proposals-submitted stakeholder) u1) })
    )

    (ok new-id)
  )
)

;; Cast a weighted vote on an active proposal.
;; A stakeholder may vote FOR (true) or AGAINST (false).
;; Vote weight equals the caller's current voting-power units.
(define-public (vote-on-proposal (proposal-id uint) (vote-for bool))
  (let (
    (caller       tx-sender)
    (stakeholder  (unwrap! (map-get? stakeholders caller)          ERR-NOT-REGISTERED))
    (proposal     (unwrap! (map-get? proposals proposal-id)        ERR-INVALID-PROPOSAL))
    (vote-key     { proposal-id: proposal-id, voter: caller })
    (voter-weight (get voting-power stakeholder))
  )
    (asserts! (is-eq (get status proposal) STATUS-ACTIVE) ERR-VOTING-CLOSED)
    (asserts! (<= stacks-block-height (get end-block proposal))  ERR-VOTING-CLOSED)
    (asserts! (is-none (map-get? votes vote-key))         ERR-ALREADY-VOTED)

    ;; Record the vote.
    (map-set votes vote-key {
      vote-for: vote-for,
      weight:   voter-weight,
      cast-at:  stacks-block-height
    })

    ;; Update running tallies on the proposal.
    (map-set proposals proposal-id (merge proposal {
      votes-for: (if vote-for
        (+ (get votes-for proposal) voter-weight)
        (get votes-for proposal)
      ),
      votes-against: (if (not vote-for)
        (+ (get votes-against proposal) voter-weight)
        (get votes-against proposal)
      ),
      total-participation: (+ (get total-participation proposal) voter-weight)
    }))

    ;; Track votes cast per stakeholder.
    (map-set stakeholders caller
      (merge stakeholder { proposals-voted: (+ (get proposals-voted stakeholder) u1) })
    )

    (ok vote-for)
  )
)

;; Finalise a proposal once its voting window has closed (callable by anyone).
;; Outcome logic:
;;   PASSED   : quorum met AND approval threshold met; escrow held for implementation.
;;   REJECTED : either condition failed; escrow returned immediately to the proposer.
(define-public (finalize-proposal (proposal-id uint))
  (let (
    (proposal    (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
    (total-power (var-get total-voting-power))
    (for-votes   (get votes-for           proposal))
    (total-votes (+ for-votes (get votes-against proposal)))
    (passed      (and
      (quorum-reached (get total-participation proposal) total-power)
      (approval-met   for-votes total-votes)
    ))
    (new-status  (if passed STATUS-PASSED STATUS-REJECTED))
  )
    (asserts! (is-eq (get status proposal) STATUS-ACTIVE)      ERR-ALREADY-FINALIZED)
    (asserts! (> stacks-block-height (get end-block proposal))        ERR-VOTING-ACTIVE)

    (map-set proposals proposal-id (merge proposal {
      status:         new-status,
      ;; Mark escrow-claimed for rejected proposals - it is returned below.
      escrow-claimed: (not passed),
      finalized-at:   stacks-block-height
    }))

    ;; Return escrow to proposer for rejected proposals; hold it for passed ones.
    (if passed
      (ok new-status)
      (begin
        (try! (as-contract (stx-transfer?
          (get escrow-amount proposal)
          tx-sender
          (get proposer proposal)
        )))
        (ok new-status)
      )
    )
  )
)

;; Mark a passed compliance rule as implemented and reclaim the escrow deposit.
;; Only the original proposer may call this, and only within the implementation window.
(define-public (implement-rule (proposal-id uint))
  (let (
    (caller   tx-sender)
    (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
  )
    (asserts! (is-eq caller (get proposer proposal))                        ERR-NOT-PROPOSER)
    (asserts! (is-eq (get status proposal) STATUS-PASSED)                  ERR-PROPOSAL-NOT-PASSED)
    (asserts! (not (get escrow-claimed proposal))                          ERR-ALREADY-IMPLEMENTED)
    (asserts! (<= stacks-block-height (get implementation-deadline proposal))     ERR-DEADLINE-PASSED)

    (map-set proposals proposal-id (merge proposal {
      status:         STATUS-IMPLEMENTED,
      escrow-claimed: true
    }))

    ;; Return the escrow as a reward for following through.
    (try! (as-contract (stx-transfer?
      (get escrow-amount proposal)
      tx-sender
      caller
    )))

    (ok true)
  )
)

;; Expire a passed proposal that missed its implementation deadline (callable by anyone).
;; The escrow is forfeited to the DAO treasury as an accountability penalty.
(define-public (expire-unimplemented-proposal (proposal-id uint))
  (let (
    (proposal (unwrap! (map-get? proposals proposal-id) ERR-INVALID-PROPOSAL))
  )
    (asserts! (is-eq (get status proposal) STATUS-PASSED) ERR-PROPOSAL-NOT-PASSED)
    (asserts! (not (get escrow-claimed proposal))         ERR-ALREADY-IMPLEMENTED)
    (asserts! (> stacks-block-height (get implementation-deadline proposal)) ERR-DEADLINE-NOT-REACHED)

    (map-set proposals proposal-id (merge proposal {
      status:         STATUS-EXPIRED,
      escrow-claimed: true
    }))

    ;; Escrow stays in the contract; update the tracked treasury balance.
    (var-set treasury-balance
      (+ (var-get treasury-balance) (get escrow-amount proposal))
    )

    (ok true)
  )
)

;; ============================================================
;; READ-ONLY FUNCTIONS
;; ============================================================

;; Return full details for a proposal.
(define-read-only (get-proposal (proposal-id uint))
  (map-get? proposals proposal-id)
)

;; Return full details for a stakeholder.
(define-read-only (get-stakeholder (addr principal))
  (map-get? stakeholders addr)
)

;; Return a specific vote record.
(define-read-only (get-vote (proposal-id uint) (voter principal))
  (map-get? votes { proposal-id: proposal-id, voter: voter })
)

;; Return the total number of proposals ever created.
(define-read-only (get-proposal-count)
  (var-get proposal-count)
)

;; Return the current aggregate voting power of all active stakeholders.
(define-read-only (get-total-voting-power)
  (var-get total-voting-power)
)

;; Return the accumulated forfeited escrow held in the DAO treasury.
(define-read-only (get-treasury-balance)
  (var-get treasury-balance)
)

;; Return the contract's live STX balance (stake + active escrow + treasury).
(define-read-only (get-contract-stx-balance)
  (stx-get-balance (as-contract tx-sender))
)

;; Return true if the proposal has met the quorum requirement at the current moment.
(define-read-only (check-quorum (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal (quorum-reached
      (get total-participation proposal)
      (var-get total-voting-power)
    )
    false
  )
)

;; Return true if the proposal has met the approval threshold at the current moment.
(define-read-only (check-approval (proposal-id uint))
  (match (map-get? proposals proposal-id)
    proposal (let (
      (for-votes   (get votes-for proposal))
      (total-votes (+ for-votes (get votes-against proposal)))
    )
      (approval-met for-votes total-votes)
    )
    false
  )
)

;; Return true if the given address is a registered stakeholder.
(define-read-only (is-registered (addr principal))
  (is-stakeholder addr)
)

;; Return the current governance parameters in a single tuple.
(define-read-only (get-governance-params)
  {
    voting-period:           VOTING-PERIOD,
    implementation-window:   IMPLEMENTATION-WINDOW,
    quorum-percentage:       QUORUM-PERCENTAGE,
    approval-percentage:     APPROVAL-PERCENTAGE,
    min-stake:               MIN-STAKE,
    proposal-escrow-amount:  PROPOSAL-ESCROW-AMOUNT
  }
)
