;; CryptoShield Protection Smart Contract in Clarity

;; Constants
(define-constant waiting-period u1500)        ;; Waiting period for premium payments (in blocks)
(define-constant max-protection u2000000)     ;; Maximum protection amount in microSTX (1 STX = 1,000,000 microSTX)

;; Data Maps
(define-map protection-plans
  { beneficiary: principal }
  { provider: principal,
    plan-fee: uint,
    plan-protection: uint,
    total-payouts: uint,
    plan-expiration: uint,
    plan-active: bool })

(define-map protection-requests
  { beneficiary: principal }
  { amount-requested: uint,
    request-approved: bool })

;; Public Functions

;; 1. Initiate a New Protection Plan
(define-public (initiate-plan (new-provider principal) (new-beneficiary principal) (fee-amount uint) (protection-amount uint))
  (begin
    ;; Ensure principals are valid (not equal to tx-sender, and fee/protection are valid amounts)
    (if (or (is-eq new-beneficiary tx-sender) (is-eq new-provider tx-sender) (<= fee-amount u0) (<= protection-amount u0))
        (err "Invalid principal or amounts")
        ;; Check if protection exceeds maximum allowed
        (if (> protection-amount max-protection)
            (err "Protection exceeds maximum allowed")
            ;; Check if a plan already exists for the beneficiary
            (if (is-some (map-get? protection-plans { beneficiary: new-beneficiary }))
                (err "An active plan already exists for this beneficiary")
                (begin
                  ;; Store the new plan
                  (map-set protection-plans
                    { beneficiary: new-beneficiary }
                    { provider: new-provider,
                      plan-fee: fee-amount,
                      plan-protection: protection-amount,
                      total-payouts: u0,
                      plan-expiration: u0,
                      plan-active: false })
                  ;; Log the event
                  (print {event: "protection-plan-created",
                          beneficiary: new-beneficiary,
                          provider: new-provider,
                          fee: fee-amount,
                          protection: protection-amount})
                  (ok "Plan initiated successfully")))))))

;; 2. Submit Fee to Activate/Renew Plan
(define-public (submit-fee (beneficiary principal))
  (let ((plan-data (map-get? protection-plans { beneficiary: beneficiary }))
        (current-height block-height))
    ;; Ensure principal is valid (not equal to tx-sender)
    (if (is-eq beneficiary tx-sender)
        (err "Invalid beneficiary principal")
        ;; Ensure the plan exists
        (if (is-some plan-data)
            (let ((active-plan (unwrap! plan-data (err "Plan unwrap failed"))))
              ;; Check if plan is inactive or due for renewal
              (if (or (not (get plan-active active-plan))
                      (<= (get plan-expiration active-plan) (+ current-height waiting-period)))
                  (begin
                    ;; Transfer fee amount to the provider
                    (unwrap! (stx-transfer? (get plan-fee active-plan) tx-sender (get provider active-plan)) (err "Transfer failed"))
                    ;; Update the plan to active and set new expiration
                    (map-set protection-plans
                      { beneficiary: beneficiary }
                      (merge active-plan
                             { plan-expiration: (+ current-height u52595),  ;; Approximately one year
                               plan-active: true }))
                    ;; Log the event
                    (print {event: "fee-paid",
                            beneficiary: beneficiary,
                            fee: (get plan-fee active-plan),
                            expiration: (+ current-height u52595)})
                    (ok "Fee submitted and plan renewed successfully"))
                  (err "Plan is active and not due for renewal")))
            (err "Plan not found")))))

;; 3. Submit a Protection Request
(define-public (submit-request (beneficiary principal) (request-amount uint))
  ;; Ensure principal and request amount are valid
  (if (or (is-eq beneficiary tx-sender) (<= request-amount u0))
      (err "Invalid principal or request amount")
      (let ((plan-data (map-get? protection-plans { beneficiary: beneficiary })))
        (if (is-some plan-data)
            (let ((active-plan (unwrap! plan-data (err "Plan unwrap failed"))))
              ;; Check if plan is active and request does not exceed protection
              (if (and (get plan-active active-plan)
                       (<= (+ (get total-payouts active-plan) request-amount)
                           (get plan-protection active-plan)))
                  (begin
                    ;; Store the request
                    (map-set protection-requests
                      { beneficiary: beneficiary }
                      { amount-requested: request-amount,
                        request-approved: false })
                    ;; Log the event
                    (print {event: "request-filed",
                            beneficiary: beneficiary,
                            request-amount: request-amount})
                    (ok "Request submitted successfully"))
                  (err "Request exceeds protection or plan is inactive")))
            (err "Plan not found")))))

;; 4. Approve a Submitted Request
(define-public (approve-request (beneficiary principal))
  ;; Ensure principal is valid
  (if (is-eq beneficiary tx-sender)
      (err "Invalid beneficiary principal")
      (let ((request-data (map-get? protection-requests { beneficiary: beneficiary })))
        (if (is-some request-data)
            (let ((filed-request (unwrap! request-data (err "Request unwrap failed"))))
              ;; Approve the request
              (map-set protection-requests
                { beneficiary: beneficiary }
                { amount-requested: (get amount-requested filed-request),
                  request-approved: true })
              ;; Log the event
              (print {event: "request-approved",
                      beneficiary: beneficiary,
                      request-amount: (get amount-requested filed-request)})
              (ok "Request approved"))
            (err "Request not found")))))

;; 5. Release Payout After Request Approval
(define-public (release-payout (beneficiary principal))
  ;; Ensure principal is valid
  (if (is-eq beneficiary tx-sender)
      (err "Invalid beneficiary principal")
      (let ((request-data (map-get? protection-requests { beneficiary: beneficiary }))
            (plan-data (map-get? protection-plans { beneficiary: beneficiary })))
        (if (and (is-some request-data) (is-some plan-data))
            (let ((approved-request (unwrap! request-data (err "Request unwrap failed")))
                  (plan (unwrap! plan-data (err "Plan unwrap failed"))))
              ;; Check if the request is approved
              (if (is-eq (get request-approved approved-request) true)
                  (let ((new-total-payouts (+ (get total-payouts plan) (get amount-requested approved-request))))
                    ;; Ensure total payouts do not exceed protection
                    (if (<= new-total-payouts (get plan-protection plan))
                        (begin
                          ;; Update the plan's total payouts
                          (map-set protection-plans
                            { beneficiary: beneficiary }
                            (merge plan { total-payouts: new-total-payouts }))
                          ;; Transfer payout amount to the beneficiary
                          (unwrap! (stx-transfer? (get amount-requested approved-request) (get provider plan) beneficiary) (err "Transfer failed"))
                          ;; Log the event
                          (print {event: "payout-released",
                                  beneficiary: beneficiary,
                                  payout-amount: (get amount-requested approved-request)})
                          (ok "Payout released successfully"))
                        (err "Payout exceeds plan protection")))
                  (err "Request not yet approved")))
            (err "Request or Plan not found")))))