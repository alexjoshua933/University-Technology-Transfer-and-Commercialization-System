;; University Technology Transfer System - Licensing and Revenue Contract
;; Manages licensing agreements and automated revenue distribution

;; Constants
(define-constant CONTRACT-OWNER tx-sender)
(define-constant ERR-NOT-AUTHORIZED (err u200))
(define-constant ERR-LICENSE-NOT-FOUND (err u201))
(define-constant ERR-INVALID-INPUT (err u202))
(define-constant ERR-TECHNOLOGY-NOT-FOUND (err u203))
(define-constant ERR-LICENSE-EXPIRED (err u204))
(define-constant ERR-INSUFFICIENT-PAYMENT (err u205))
(define-constant ERR-INVALID-REVENUE-SHARE (err u206))
(define-constant ERR-LICENSE-ALREADY-EXISTS (err u207))
(define-constant ERR-INVALID-LICENSE-TYPE (err u208))
(define-constant ERR-DISTRIBUTION-FAILED (err u209))

;; Maximum revenue share percentage (10000 = 100%)
(define-constant MAX-REVENUE-SHARE u10000)

;; Data Variables
(define-data-var next-license-id uint u1)
(define-data-var total-licenses uint u0)
(define-data-var total-revenue-distributed uint u0)

;; Data Maps
(define-map licenses
  { id: uint }
  {
    technology-id: uint,
    licensee: principal,
    licensor: principal,
    license-type: (string-ascii 50),
    revenue-share: uint,
    minimum-royalty: uint,
    upfront-payment: uint,
    territory: (string-ascii 100),
    field-of-use: (string-ascii 200),
    duration: uint,
    start-date: uint,
    end-date: uint,
    status: (string-ascii 20),
    created-at: uint,
    updated-at: uint,
    auto-renewal: bool,
    sublicense-allowed: bool
  }
)

(define-map revenue-distributions
  { license-id: uint, payment-id: uint }
  {
    total-amount: uint,
    university-share: uint,
    inventor-shares: (list 10 { inventor: principal, amount: uint }),
    licensee: principal,
    payment-date: uint,
    revenue-period-start: uint,
    revenue-period-end: uint,
    distribution-completed: bool
  }
)

(define-map license-payments
  { license-id: uint }
  {
    total-paid: uint,
    last-payment: uint,
    last-payment-date: uint,
    payment-count: uint,
    overdue-amount: uint,
    next-payment-due: uint
  }
)

(define-map revenue-sharing-rules
  { technology-id: uint }
  {
    university-percentage: uint,
    inventor-percentages: (list 10 { inventor: principal, percentage: uint }),
    overhead-percentage: uint,
    research-fund-percentage: uint,
    total-percentage: uint
  }
)

(define-map licensee-profiles
  { licensee: principal }
  {
    company-name: (string-ascii 200),
    license-count: uint,
    total-payments: uint,
    compliance-score: uint,
    last-activity: uint,
    status: (string-ascii 20)
  }
)

(define-map technology-licenses
  { technology-id: uint }
  {
    license-ids: (list 50 uint),
    exclusive-license: (optional uint),
    total-revenue: uint,
    active-licenses: uint
  }
)

;; Authorization Functions
(define-private (is-contract-owner)
  (is-eq tx-sender CONTRACT-OWNER)
)

(define-private (is-license-party (license-id uint) (user principal))
  (match (map-get? licenses { id: license-id })
    license-data (or
      (is-eq (get licensee license-data) user)
      (is-eq (get licensor license-data) user)
    )
    false
  )
)

;; Validation Functions
(define-private (is-valid-license-type (license-type (string-ascii 50)))
  (or
    (is-eq license-type "exclusive")
    (is-eq license-type "non-exclusive")
    (is-eq license-type "sole")
    (is-eq license-type "co-exclusive")
  )
)

(define-private (is-valid-license-status (status (string-ascii 20)))
  (or
    (is-eq status "active")
    (is-eq status "pending")
    (is-eq status "expired")
    (is-eq status "terminated")
    (is-eq status "suspended")
  )
)

(define-private (is-license-active (license-id uint))
  (match (map-get? licenses { id: license-id })
    license-data (and
      (is-eq (get status license-data) "active")
      (>= block-height (get start-date license-data))
      (<= block-height (get end-date license-data))
    )
    false
  )
)

;; Core Functions

;; Create a new license agreement
(define-public (create-license
  (technology-id uint)
  (licensee principal)
  (licensor principal)
  (license-type (string-ascii 50))
  (revenue-share uint)
  (minimum-royalty uint)
  (upfront-payment uint)
  (territory (string-ascii 100))
  (field-of-use (string-ascii 200))
  (duration uint)
)
  (let (
    (license-id (var-get next-license-id))
    (current-block-height block-height)
    (end-date (+ current-block-height duration))
  )
    ;; Validate inputs
    (asserts! (> technology-id u0) ERR-TECHNOLOGY-NOT-FOUND)
    (asserts! (is-valid-license-type license-type) ERR-INVALID-LICENSE-TYPE)
    (asserts! (<= revenue-share MAX-REVENUE-SHARE) ERR-INVALID-REVENUE-SHARE)
    (asserts! (> duration u0) ERR-INVALID-INPUT)
    (asserts! (> (len territory) u0) ERR-INVALID-INPUT)

    ;; Check for existing exclusive license if this is exclusive
    (if (is-eq license-type "exclusive")
      (asserts! (is-none (get-exclusive-license technology-id)) ERR-LICENSE-ALREADY-EXISTS)
      true
    )

    ;; Create license record
    (map-set licenses
      { id: license-id }
      {
        technology-id: technology-id,
        licensee: licensee,
        licensor: licensor,
        license-type: license-type,
        revenue-share: revenue-share,
        minimum-royalty: minimum-royalty,
        upfront-payment: upfront-payment,
        territory: territory,
        field-of-use: field-of-use,
        duration: duration,
        start-date: current-block-height,
        end-date: end-date,
        status: "pending",
        created-at: current-block-height,
        updated-at: current-block-height,
        auto-renewal: false,
        sublicense-allowed: false
      }
    )

    ;; Initialize payment tracking
    (map-set license-payments
      { license-id: license-id }
      {
        total-paid: u0,
        last-payment: u0,
        last-payment-date: u0,
        payment-count: u0,
        overdue-amount: u0,
        next-payment-due: (+ current-block-height u52560) ;; ~1 year in blocks
      }
    )

    ;; Update technology licenses
    (update-technology-license-list technology-id license-id license-type)

    ;; Update licensee profile
    (update-licensee-profile licensee)

    ;; Update counters
    (var-set next-license-id (+ license-id u1))
    (var-set total-licenses (+ (var-get total-licenses) u1))

    (ok license-id)
  )
)

;; Activate a license agreement
(define-public (activate-license (license-id uint))
  (let (
    (license-data (unwrap! (map-get? licenses { id: license-id }) ERR-LICENSE-NOT-FOUND))
  )
    ;; Authorization check
    (asserts! (or
      (is-eq (get licensor license-data) tx-sender)
      (is-contract-owner)
    ) ERR-NOT-AUTHORIZED)

    ;; Validate current status
    (asserts! (is-eq (get status license-data) "pending") ERR-INVALID-INPUT)

    ;; Update license status
    (map-set licenses
      { id: license-id }
      (merge license-data {
        status: "active",
        updated-at: block-height
      })
    )

    ;; Update technology license tracking
    (let ((tech-licenses (default-to
      { license-ids: (list), exclusive-license: none, total-revenue: u0, active-licenses: u0 }
      (map-get? technology-licenses { technology-id: (get technology-id license-data) })
    )))
      (map-set technology-licenses
        { technology-id: (get technology-id license-data) }
        (merge tech-licenses {
          active-licenses: (+ (get active-licenses tech-licenses) u1),
          exclusive-license: (if (is-eq (get license-type license-data) "exclusive")
            (some license-id)
            (get exclusive-license tech-licenses)
          )
        })
      )
    )

    (ok true)
  )
)

;; Process revenue payment and distribution
(define-public (process-revenue-payment
  (license-id uint)
  (payment-amount uint)
  (revenue-period-start uint)
  (revenue-period-end uint)
)
  (let (
    (license-data (unwrap! (map-get? licenses { id: license-id }) ERR-LICENSE-NOT-FOUND))
    (payment-id (+ (get payment-count (default-to
      { total-paid: u0, last-payment: u0, last-payment-date: u0, payment-count: u0, overdue-amount: u0, next-payment-due: u0 }
      (map-get? license-payments { license-id: license-id })
    )) u1))
  )
    ;; Validate license is active
    (asserts! (is-license-active license-id) ERR-LICENSE-EXPIRED)

    ;; Authorization check
    (asserts! (is-eq (get licensee license-data) tx-sender) ERR-NOT-AUTHORIZED)

    ;; Validate payment amount meets minimum
    (let ((calculated-royalty (/ (* payment-amount (get revenue-share license-data)) u10000)))
      (asserts! (>= calculated-royalty (get minimum-royalty license-data)) ERR-INSUFFICIENT-PAYMENT)
    )

    ;; Get revenue sharing rules
    (let (
      (sharing-rules (unwrap! (map-get? revenue-sharing-rules { technology-id: (get technology-id license-data) }) ERR-INVALID-INPUT))
      (royalty-amount (/ (* payment-amount (get revenue-share license-data)) u10000))
    )
      ;; Calculate distributions
      (let (
        (university-amount (/ (* royalty-amount (get university-percentage sharing-rules)) u10000))
        (inventor-distributions (calculate-inventor-distributions royalty-amount (get inventor-percentages sharing-rules)))
      )
        ;; Record revenue distribution
        (map-set revenue-distributions
          { license-id: license-id, payment-id: payment-id }
          {
            total-amount: royalty-amount,
            university-share: university-amount,
            inventor-shares: inventor-distributions,
            licensee: (get licensee license-data),
            payment-date: block-height,
            revenue-period-start: revenue-period-start,
            revenue-period-end: revenue-period-end,
            distribution-completed: false
          }
        )

        ;; Update payment tracking
        (update-payment-tracking license-id payment-amount)

        ;; Update technology revenue
        (update-technology-revenue (get technology-id license-data) royalty-amount)

        ;; Update total distributed revenue
        (var-set total-revenue-distributed (+ (var-get total-revenue-distributed) royalty-amount))

        (ok payment-id)
      )
    )
  )
)

;; Set revenue sharing rules for a technology
(define-public (set-revenue-sharing-rules
  (technology-id uint)
  (university-percentage uint)
  (inventor-percentages (list 10 { inventor: principal, percentage: uint }))
  (overhead-percentage uint)
  (research-fund-percentage uint)
)
  (let (
    (total-percentage (+ university-percentage overhead-percentage research-fund-percentage
      (fold + (map get-percentage inventor-percentages) u0)))
  )
    ;; Authorization check (only contract owner or university can set rules)
    (asserts! (is-contract-owner) ERR-NOT-AUTHORIZED)

    ;; Validate percentages sum to 100%
    (asserts! (is-eq total-percentage u10000) ERR-INVALID-REVENUE-SHARE)

    ;; Set revenue sharing rules
    (map-set revenue-sharing-rules
      { technology-id: technology-id }
      {
        university-percentage: university-percentage,
        inventor-percentages: inventor-percentages,
        overhead-percentage: overhead-percentage,
        research-fund-percentage: research-fund-percentage,
        total-percentage: total-percentage
      }
    )

    (ok true)
  )
)

;; Update license status
(define-public (update-license-status (license-id uint) (new-status (string-ascii 20)))
  (let (
    (license-data (unwrap! (map-get? licenses { id: license-id }) ERR-LICENSE-NOT-FOUND))
  )
    ;; Authorization check
    (asserts! (or
      (is-license-party license-id tx-sender)
      (is-contract-owner)
    ) ERR-NOT-AUTHORIZED)

    ;; Validate status
    (asserts! (is-valid-license-status new-status) ERR-INVALID-INPUT)

    ;; Update license status
    (map-set licenses
      { id: license-id }
      (merge license-data {
        status: new-status,
        updated-at: block-height
      })
    )

    (ok true)
  )
)

;; Private helper functions
(define-private (get-percentage (item { inventor: principal, percentage: uint }))
  (get percentage item)
)

(define-private (calculate-inventor-distributions
  (total-amount uint)
  (inventor-percentages (list 10 { inventor: principal, percentage: uint }))
)
  (map calculate-single-inventor-share
    inventor-percentages
    (list total-amount total-amount total-amount total-amount total-amount
          total-amount total-amount total-amount total-amount total-amount)
  )
)

(define-private (calculate-single-inventor-share
  (inventor-data { inventor: principal, percentage: uint })
  (total-amount uint)
)
  {
    inventor: (get inventor inventor-data),
    amount: (/ (* total-amount (get percentage inventor-data)) u10000)
  }
)

(define-private (update-technology-license-list (technology-id uint) (license-id uint) (license-type (string-ascii 50)))
  (let (
    (current-data (default-to
      { license-ids: (list), exclusive-license: none, total-revenue: u0, active-licenses: u0 }
      (map-get? technology-licenses { technology-id: technology-id })
    ))
    (updated-ids (unwrap! (as-max-len? (append (get license-ids current-data) license-id) u50) false))
  )
    (map-set technology-licenses
      { technology-id: technology-id }
      (merge current-data {
        license-ids: updated-ids
      })
    )
  )
)

(define-private (update-licensee-profile (licensee principal))
  (let (
    (current-profile (default-to
      { company-name: "", license-count: u0, total-payments: u0, compliance-score: u100, last-activity: u0, status: "active" }
      (map-get? licensee-profiles { licensee: licensee })
    ))
  )
    (map-set licensee-profiles
      { licensee: licensee }
      (merge current-profile {
        license-count: (+ (get license-count current-profile) u1),
        last-activity: block-height
      })
    )
  )
)

(define-private (update-payment-tracking (license-id uint) (payment-amount uint))
  (let (
    (current-payments (default-to
      { total-paid: u0, last-payment: u0, last-payment-date: u0, payment-count: u0, overdue-amount: u0, next-payment-due: u0 }
      (map-get? license-payments { license-id: license-id })
    ))
  )
    (map-set license-payments
      { license-id: license-id }
      (merge current-payments {
        total-paid: (+ (get total-paid current-payments) payment-amount),
        last-payment: payment-amount,
        last-payment-date: block-height,
        payment-count: (+ (get payment-count current-payments) u1),
        next-payment-due: (+ block-height u52560) ;; Next year
      })
    )
  )
)

(define-private (update-technology-revenue (technology-id uint) (revenue-amount uint))
  (let (
    (current-data (default-to
      { license-ids: (list), exclusive-license: none, total-revenue: u0, active-licenses: u0 }
      (map-get? technology-licenses { technology-id: technology-id })
    ))
  )
    (map-set technology-licenses
      { technology-id: technology-id }
      (merge current-data {
        total-revenue: (+ (get total-revenue current-data) revenue-amount)
      })
    )
  )
)

;; Read-only functions

;; Get license details
(define-read-only (get-license (license-id uint))
  (map-get? licenses { id: license-id })
)

;; Get license payment information
(define-read-only (get-license-payments (license-id uint))
  (map-get? license-payments { license-id: license-id })
)

;; Get revenue distribution details
(define-read-only (get-revenue-distribution (license-id uint) (payment-id uint))
  (map-get? revenue-distributions { license-id: license-id, payment-id: payment-id })
)

;; Get revenue sharing rules
(define-read-only (get-revenue-sharing-rules (technology-id uint))
  (map-get? revenue-sharing-rules { technology-id: technology-id })
)

;; Get technology licenses
(define-read-only (get-technology-licenses (technology-id uint))
  (map-get? technology-licenses { technology-id: technology-id })
)

;; Get exclusive license for technology
(define-read-only (get-exclusive-license (technology-id uint))
  (match (map-get? technology-licenses { technology-id: technology-id })
    tech-licenses (get exclusive-license tech-licenses)
    none
  )
)

;; Get licensee profile
(define-read-only (get-licensee-profile (licensee principal))
  (map-get? licensee-profiles { licensee: licensee })
)

;; Get total licenses count
(define-read-only (get-total-licenses)
  (var-get total-licenses)
)

;; Get total revenue distributed
(define-read-only (get-total-revenue-distributed)
  (var-get total-revenue-distributed)
)

;; Check if license is active
(define-read-only (check-license-active (license-id uint))
  (is-license-active license-id)
)

;; Get next license ID
(define-read-only (get-next-license-id)
  (var-get next-license-id)
)
