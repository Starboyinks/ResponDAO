;; ResponDAO: Decentralized Community Disaster Relief Fund
;; Written in Clarity for Stacks blockchain

;; Constants
(define-constant CONTRACT_OWNER tx-sender)
(define-constant MIN_DONATION u100000) ;; Minimum donation in microSTX (0.1 STX)
(define-constant REQUIRED_APPROVALS u2) ;; Number of required approvals for fund release

;; Data Variables
(define-data-var total-funds uint u0)
(define-data-var oracle-address principal 'SP000000000000000000002Q6VF78) ;; Example oracle address

;; Data Maps
(define-map community-leaders principal bool)
(define-map fund-requests 
    uint 
    {
        requestor: principal,
        amount: uint,
        approvals: uint,
        status: (string-ascii 20),
        disaster-type: (string-ascii 50)
    }
)
(define-map approval-status 
    {request-id: uint, approver: principal} 
    bool
)

;; Counter for request IDs
(define-data-var request-counter uint u0)

;; Error constants
(define-constant ERR_NOT_AUTHORIZED (err u100))
(define-constant ERR_INSUFFICIENT_FUNDS (err u101))
(define-constant ERR_INVALID_REQUEST (err u102))
(define-constant ERR_ALREADY_APPROVED (err u103))
(define-constant ERR_REQUEST_COMPLETED (err u104))

;; Administrative Functions

(define-public (add-community-leader (leader principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (ok (map-set community-leaders leader true))))

(define-public (remove-community-leader (leader principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (ok (map-set community-leaders leader false))))

;; Oracle Functions

(define-public (update-oracle-address (new-oracle principal))
    (begin
        (asserts! (is-eq tx-sender CONTRACT_OWNER) ERR_NOT_AUTHORIZED)
        (var-set oracle-address new-oracle)
        (ok true)))

;; Fund Management Functions

(define-public (donate)
    (let ((amount (stx-get-balance tx-sender)))
        (begin
            (asserts! (>= amount MIN_DONATION) ERR_INSUFFICIENT_FUNDS)
            (try! (stx-transfer? amount tx-sender (as-contract tx-sender)))
            (var-set total-funds (+ (var-get total-funds) amount))
            (ok amount))))

(define-public (request-funds (amount uint) (disaster-type (string-ascii 50)))
    (let ((request-id (+ (var-get request-counter) u1)))
        (begin
            (asserts! (<= amount (var-get total-funds)) ERR_INSUFFICIENT_FUNDS)
            (map-set fund-requests request-id {
                requestor: tx-sender,
                amount: amount,
                approvals: u0,
                status: "PENDING",
                disaster-type: disaster-type
            })
            (var-set request-counter request-id)
            (ok request-id))))

(define-public (approve-request (request-id uint))
    (let (
        (request (unwrap! (map-get? fund-requests request-id) ERR_INVALID_REQUEST))
        (approval-key {request-id: request-id, approver: tx-sender})
    )
        (begin
            (asserts! (default-to false (map-get? community-leaders tx-sender)) ERR_NOT_AUTHORIZED)
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
    (let ((request (unwrap! (map-get? fund-requests request-id) ERR_INVALID_REQUEST)))
        (begin
            (try! (as-contract (stx-transfer? (get amount request) tx-sender (get requestor request))))
            (var-set total-funds (- (var-get total-funds) (get amount request)))
            (map-set fund-requests request-id 
                (merge request {
                    status: "COMPLETED"
                })
            )
            (ok true))))

;; Oracle-triggered release
(define-public (oracle-trigger-release (request-id uint))
    (begin
        (asserts! (is-eq tx-sender (var-get oracle-address)) ERR_NOT_AUTHORIZED)
        (release-funds request-id)))

;; Read-only Functions

(define-read-only (get-total-funds)
    (ok (var-get total-funds)))

(define-read-only (get-request (request-id uint))
    (ok (map-get? fund-requests request-id)))

(define-read-only (is-community-leader (address principal))
    (ok (default-to false (map-get? community-leaders address))))