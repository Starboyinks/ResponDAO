;; ResponDAO: Decentralized Community Disaster Relief Fund
;; Written in Clarity for Stacks blockchain

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_DONATION u100000) 
(define-constant REQUIRED_APPROVALS u2)
(define-constant ESCROW_LOCK_PERIOD u144) ;; ~24 hours in blocks

;; Data Variables
(define-data-var total-funds uint u0)
(define-data-var oracle-address principal 'SP000000000000000000002Q6VF78)

;; Enhanced Data Maps
(define-map community-leaders principal bool)
(define-map verified-disasters 
    uint 
    {
        disaster-id: uint,
        disaster-type: (string-ascii 50),
        location: (string-ascii 100),
        timestamp: uint,
        is-active: bool
    }
)
(define-map escrow-funds
    uint  ;; disaster-id
    {
        amount: uint,
        unlock-height: uint,
        beneficiary: principal
    }
)
(define-map fund-requests 
    uint 
    {
        requestor: principal,
        amount: uint,
        approvals: uint,
        status: (string-ascii 20),
        disaster-type: (string-ascii 50),
        disaster-id: uint
    }
)
(define-map approval-status 
    {request-id: uint, approver: principal} 
    bool
)

;; Counters
(define-data-var request-counter uint u0)
(define-data-var disaster-counter uint u0)

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_FUNDS (err u101))
(define-constant ERR_INVALID_REQUEST (err u102))
(define-constant ERR_ALREADY_APPROVED (err u103))
(define-constant ERR_REQUEST_COMPLETED (err u104))
(define-constant ERR_INVALID_DISASTER (err u105))
(define-constant ERR_ESCROW_LOCKED (err u106))
(define-constant ERR_DISASTER_INACTIVE (err u107))

;; Administrative Functions
(define-public (add-community-leader (leader principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (ok (map-set community-leaders leader true))))

(define-public (remove-community-leader (leader principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (ok (map-set community-leaders leader false))))

;; Disaster Management
(define-public (register-disaster 
    (disaster-type (string-ascii 50))
    (location (string-ascii 100)))
    (let ((disaster-id (+ (var-get disaster-counter) u1)))
        (begin
            (asserts! (default-to false (map-get? community-leaders tx-sender)) ERR_NOT_AUTHORIZED)
            (map-set verified-disasters disaster-id {
                disaster-id: disaster-id,
                disaster-type: disaster-type,
                location: location,
                timestamp: block-height,
                is-active: true
            })
            (var-set disaster-counter disaster-id)
            (ok disaster-id))))

(define-public (close-disaster (disaster-id uint))
    (let ((disaster (unwrap! (map-get? verified-disasters disaster-id) ERR_INVALID_DISASTER)))
        (begin
            (asserts! (default-to false (map-get? community-leaders tx-sender)) ERR_NOT_AUTHORIZED)
            (map-set verified-disasters disaster-id 
                (merge disaster {
                    is-active: false
                })
            )
            (ok true))))

;; Escrow Management
(define-public (donate-to-disaster (disaster-id uint))
    (let (
        (disaster (unwrap! (map-get? verified-disasters disaster-id) ERR_INVALID_DISASTER))
        (amount (stx-get-balance tx-sender))
    )
        (begin
            (asserts! (get is-active disaster) ERR_DISASTER_INACTIVE)
            (asserts! (>= amount MIN_DONATION) ERR_INSUFFICIENT_FUNDS)
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            (var-set total-funds (+ (var-get total-funds) amount))
            (map-set escrow-funds disaster-id {
                amount: amount,
                unlock-height: (+ block-height ESCROW_LOCK_PERIOD),
                beneficiary: tx-sender
            })
            (ok amount))))

(define-public (request-funds (amount uint) (disaster-id uint))
    (let (
        (disaster (unwrap! (map-get? verified-disasters disaster-id) ERR_INVALID_DISASTER))
        (request-id (+ (var-get request-counter) u1))
    )
        (begin
            (asserts! (get is-active disaster) ERR_DISASTER_INACTIVE)
            (asserts! (<= amount (var-get total-funds)) ERR_INSUFFICIENT_FUNDS)
            (map-set fund-requests request-id {
                requestor: tx-sender,
                amount: amount,
                approvals: u0,
                status: "PENDING",
                disaster-type: (get disaster-type disaster),
                disaster-id: disaster-id
            })
            (var-set request-counter request-id)
            (ok request-id))))

(define-public (approve-request (request-id uint))
    (let (
        (request (unwrap! (map-get? fund-requests request-id) ERR_INVALID_REQUEST))
        (approval-key {request-id: request-id, approver: tx-sender})
        (disaster (unwrap! (map-get? verified-disasters (get disaster-id request)) ERR_INVALID_DISASTER))
    )
        (begin
            (asserts! (default-to false (map-get? community-leaders tx-sender)) ERR_NOT_AUTHORIZED)
            (asserts! (get is-active disaster) ERR_DISASTER_INACTIVE)
            (asserts! (is-eq (get status request) "PENDING") ERR_REQUEST_COMPLETED)
            (asserts! (not (default-to false (map-get? approval-status approval-key))) ERR_ALREADY_APPROVED)
            
            (map-set approval-status approval-key true)
            (map-set fund-requests request-id 
                (merge request {
                    approvals: (+ (get approvals request) u1)
                })
            )
            
            (if (>= (+ (get approvals request) u1) REQUIRED_APPROVALS)
                (release-funds request-id)
                (ok true)))))

(define-private (release-funds (request-id uint))
    (let (
        (request (unwrap! (map-get? fund-requests request-id) ERR_INVALID_REQUEST))
        (escrow (unwrap! (map-get? escrow-funds (get disaster-id request)) ERR_INVALID_REQUEST))
    )
        (begin
            (asserts! (>= block-height (get unlock-height escrow)) ERR_ESCROW_LOCKED)
            (try! (as-contract (stx-transfer? (get amount request) tx-sender (get requestor request))))
            (var-set total-funds (- (var-get total-funds) (get amount request)))
            (map-set fund-requests request-id 
                (merge request {
                    status: "COMPLETED"
                })
            )
            (ok true))))

;; Oracle Functions
(define-public (oracle-trigger-release (request-id uint))
    (begin
        (asserts! (is-eq tx-sender (var-get oracle-address)) ERR_NOT_AUTHORIZED)
        (release-funds request-id)))

;; Read-only Functions
(define-read-only (get-total-funds)
    (ok (var-get total-funds)))

(define-read-only (get-request (request-id uint))
    (ok (map-get? fund-requests request-id)))

(define-read-only (get-disaster (disaster-id uint))
    (ok (map-get? verified-disasters disaster-id)))

(define-read-only (get-escrow (disaster-id uint))
    (ok (map-get? escrow-funds disaster-id)))

(define-read-only (is-community-leader (address principal))
    (ok (default-to false (map-get? community-leaders address))))