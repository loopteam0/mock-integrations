#!/usr/bin/env bash
set -euo pipefail

BASE_URL="${KORA_MOCK_URL:-http://localhost:8080}"
AUTH_HEADER="Authorization: Bearer sk_test_kora_stateful_mock_2025"
OFFLINE_ONLY=false

for arg in "$@"; do
  case "$arg" in
    --offline-only)
      OFFLINE_ONLY=true
      ;;
  esac
done

PASS_COUNT=0
FAIL_COUNT=0

pass() {
  echo "✅ [PASS] $1"
  PASS_COUNT=$((PASS_COUNT + 1))
}

fail() {
  echo "❌ [FAIL] $1" >&2
  FAIL_COUNT=$((FAIL_COUNT + 1))
}

echo "================================================================="
echo " Kora API Stateful WireMock Verification Suite (TC-01 to TC-52)"
echo "================================================================="

# ------------------------------------------------------------------
# TC-01: Offline JSON syntax & structure validation
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-01: JSON Syntax & Mapping Structure Validation ---"
JSON_VALID=true
for f in wiremock/mappings/*.json wiremock/__files/*.json; do
  if ! jq empty "$f" 2>/dev/null; then
    fail "TC-01: Invalid JSON syntax in $f"
    JSON_VALID=false
  fi
done

MAPPING_COUNT=$(ls -1 wiremock/mappings/*.json 2>/dev/null | wc -l | tr -d ' ')
if [ "$JSON_VALID" = true ] && [ "$MAPPING_COUNT" -ge 24 ]; then
  pass "TC-01: All ${MAPPING_COUNT} mapping files and body files are valid JSON"
else
  fail "TC-01: Mapping validation failed (count=${MAPPING_COUNT})"
fi

if [ "$OFFLINE_ONLY" = true ]; then
  echo ""
  echo "Offline validation complete. Passed: ${PASS_COUNT}, Failed: ${FAIL_COUNT}"
  [ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
fi

# ------------------------------------------------------------------
# TC-02: WireMock Health Check
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-02: WireMock Health & Readiness Check ---"
HTTP_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/__admin/health" || echo "000")
if [ "$HTTP_CODE" = "200" ]; then
  pass "TC-02: WireMock /__admin/health returned 200 OK"
else
  fail "TC-02: WireMock /__admin/health returned ${HTTP_CODE} (is the server running on ${BASE_URL}?)"
  exit 1
fi

# Reset scenarios before running live tests
curl -s -X POST "${BASE_URL}/__admin/scenarios/reset" >/dev/null

# ------------------------------------------------------------------
# TC-03: Auth Guard - Missing Authorization Header
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-03: Missing Authorization Header ---"
RESP=$(curl -s -w "\n%{http_code}" "${BASE_URL}/merchant/api/v1/balances")
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
STATUS_VAL=$(echo "$BODY" | jq -r '.status')
if [ "$CODE" = "401" ] && [ "$STATUS_VAL" = "false" ]; then
  pass "TC-03: Missing Authorization header rejected with 401 Unauthorized"
else
  fail "TC-03: Expected 401/false, got ${CODE}/${STATUS_VAL}"
fi

# ------------------------------------------------------------------
# TC-04: Auth Guard - Malformed Authorization Header
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-04: Malformed Authorization Header ---"
RESP=$(curl -s -w "\n%{http_code}" -H "Authorization: Basic 12345" "${BASE_URL}/merchant/api/v1/balances")
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
STATUS_VAL=$(echo "$BODY" | jq -r '.status')
if [ "$CODE" = "401" ] && [ "$STATUS_VAL" = "false" ]; then
  pass "TC-04: Malformed Authorization header rejected with 401 Unauthorized"
else
  fail "TC-04: Expected 401/false, got ${CODE}/${STATUS_VAL}"
fi

# ------------------------------------------------------------------
# TC-05: Unknown Charge Reference Returns 404
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-05: Unknown Charge Reference Returns 404 ---"
RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/NON-EXISTENT-REF-999")
BODY=$(echo "$RESP" | sed '$d')
CODE=$(echo "$RESP" | tail -n1)
STATUS_VAL=$(echo "$BODY" | jq -r '.status')
if [ "$CODE" = "404" ] && [ "$STATUS_VAL" = "false" ]; then
  pass "TC-05: Unknown charge reference NON-EXISTENT-REF-999 returned 404 Not Found"
else
  fail "TC-05: Expected 404/false, got ${CODE}/${STATUS_VAL} (${BODY})"
fi

# ------------------------------------------------------------------
# TC-06: Stateful Initialize Charge -> Query Charge Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-06: Stateful Initialize Charge -> Query Charge Round-Trip ---"
INIT_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/initialize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "amount": "25000.50",
    "currency": "NGN",
    "reference": "KORA-DYN-001",
    "narration": "Order #1001 Payment",
    "customer": {
      "name": "Alice Wonderland",
      "email": "alice@kora.test"
    }
  }')
INIT_BODY=$(echo "$INIT_RESP" | sed '$d')
INIT_CODE=$(echo "$INIT_RESP" | tail -n1)
CHECKOUT_URL=$(echo "$INIT_BODY" | jq -r '.data.checkout_url')

GET_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/KORA-DYN-001")
GET_BODY=$(echo "$GET_RESP" | sed '$d')
GET_CODE=$(echo "$GET_RESP" | tail -n1)
GET_REF=$(echo "$GET_BODY" | jq -r '.data.reference')
GET_AMT=$(echo "$GET_BODY" | jq -r '.data.amount | tostring')
GET_EMAIL=$(echo "$GET_BODY" | jq -r '.data.customer.email')

if [ "$INIT_CODE" = "200" ] && [[ "$CHECKOUT_URL" == *"KORA-DYN-001"* ]] && \
   [ "$GET_CODE" = "200" ] && [ "$GET_REF" = "KORA-DYN-001" ] && \
   { [ "$GET_AMT" = "25000.50" ] || [ "$GET_AMT" = "25000.5" ]; } && \
   [ "$GET_EMAIL" = "alice@kora.test" ]; then
  pass "TC-06: Dynamic charge KORA-DYN-001 persisted and verified via GET /charges/KORA-DYN-001"
else
  fail "TC-06: Failed round-trip (init=${INIT_CODE}, get=${GET_CODE}, ref=${GET_REF}, amt=${GET_AMT}, email=${GET_EMAIL})"
fi

# ------------------------------------------------------------------
# TC-07: Stateful Bank Transfer Charge -> Query Charge Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-07: Stateful Bank Transfer Charge -> Query Charge Round-Trip ---"
BT_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/bank-transfer" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "account_name": "Bob Builder Virtual",
    "amount": 15000,
    "currency": "NGN",
    "reference": "KORA-BT-001",
    "customer": {
      "name": "Bob Builder",
      "email": "bob@kora.test"
    }
  }')
BT_BODY=$(echo "$BT_RESP" | sed '$d')
BT_CODE=$(echo "$BT_RESP" | tail -n1)
BANK_ACC=$(echo "$BT_BODY" | jq -r '.data.bank_account.account_number')

BT_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/KORA-BT-001")
BT_GET_BODY=$(echo "$BT_GET" | sed '$d')
BT_GET_CODE=$(echo "$BT_GET" | tail -n1)
BT_GET_REF=$(echo "$BT_GET_BODY" | jq -r '.data.reference')
BT_GET_AMT=$(echo "$BT_GET_BODY" | jq -r '.data.amount | tostring')

if [ "$BT_CODE" = "200" ] && [ -n "$BANK_ACC" ] && [ "$BANK_ACC" != "null" ] && \
   [ "$BT_GET_CODE" = "200" ] && [ "$BT_GET_REF" = "KORA-BT-001" ] && [ "$BT_GET_AMT" = "15000" ]; then
  pass "TC-07: Bank transfer charge KORA-BT-001 persisted and verified via GET /charges/KORA-BT-001"
else
  fail "TC-07: Failed bank transfer round-trip (post=${BT_CODE}, get=${BT_GET_CODE}, ref=${BT_GET_REF}, amt=${BT_GET_AMT})"
fi

# ------------------------------------------------------------------
# TC-08: Stateful Mobile Money Charge -> Query Charge Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-08: Stateful Mobile Money Charge -> Query Charge Round-Trip ---"
MM_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/mobile-money" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "KORA-MOMO-001",
    "amount": 3000,
    "currency": "KES",
    "mobile_money": {
      "number": "254700000000"
    },
    "customer": {
      "name": "Kenya User",
      "email": "kenya@kora.test"
    }
  }')
MM_CODE=$(echo "$MM_RESP" | tail -n1)

MM_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/KORA-MOMO-001")
MM_GET_BODY=$(echo "$MM_GET" | sed '$d')
MM_GET_CODE=$(echo "$MM_GET" | tail -n1)
MM_CURR=$(echo "$MM_GET_BODY" | jq -r '.data.currency')
MM_AMT=$(echo "$MM_GET_BODY" | jq -r '.data.amount | tostring')

if [ "$MM_CODE" = "200" ] && [ "$MM_GET_CODE" = "200" ] && [ "$MM_CURR" = "KES" ] && [ "$MM_AMT" = "3000" ]; then
  pass "TC-08: Mobile money charge KORA-MOMO-001 persisted and verified via GET /charges/KORA-MOMO-001"
else
  fail "TC-08: Failed mobile money round-trip (post=${MM_CODE}, get=${MM_GET_CODE}, curr=${MM_CURR}, amt=${MM_AMT})"
fi

# ------------------------------------------------------------------
# TC-09: Stateful Single Payout Disburse -> Query Transaction Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-09: Stateful Single Payout Disburse -> Query Transaction Round-Trip ---"
DISB_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/transactions/disburse" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "PAYOUT-DYN-001",
    "destination": {
      "type": "bank_account",
      "amount": 50000,
      "currency": "NGN",
      "narration": "Contractor Payout",
      "bank_account": {
        "bank": "033",
        "account": "2158634852"
      },
      "customer": {
        "name": "Ebuka Ciroma",
        "email": "ebuka@kora.test"
      }
    }
  }')
DISB_CODE=$(echo "$DISB_RESP" | tail -n1)

TX_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/PAYOUT-DYN-001")
TX_GET_BODY=$(echo "$TX_GET" | sed '$d')
TX_GET_CODE=$(echo "$TX_GET" | tail -n1)
TX_REF=$(echo "$TX_GET_BODY" | jq -r '.data.reference')
TX_AMT=$(echo "$TX_GET_BODY" | jq -r '.data.amount | tostring')

if [ "$DISB_CODE" = "200" ] && [ "$TX_GET_CODE" = "200" ] && [ "$TX_REF" = "PAYOUT-DYN-001" ] && [ "$TX_AMT" = "50000" ]; then
  pass "TC-09: Single payout PAYOUT-DYN-001 persisted and verified via GET /transactions/PAYOUT-DYN-001"
else
  fail "TC-09: Failed payout round-trip (post=${DISB_CODE}, get=${TX_GET_CODE}, ref=${TX_REF}, amt=${TX_AMT})"
fi

# ------------------------------------------------------------------
# TC-10: Bulk Payout Disburse
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-10: Bulk Payout Disburse ---"
BULK_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/transactions/disburse/bulk" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "batch_reference": "BATCH-001",
    "description": "Monthly Payroll",
    "merchant_bears_cost": true,
    "currency": "NGN",
    "payouts": [
      {
        "reference": "BULK-ITEM-1",
        "amount": 50000,
        "type": "bank_account",
        "narration": "Salary 1",
        "bank_account": { "bank_code": "033", "account_number": "2158634852" },
        "customer": { "name": "Staff One", "email": "staff1@kora.test" }
      }
    ]
  }')
BULK_BODY=$(echo "$BULK_RESP" | sed '$d')
BULK_CODE=$(echo "$BULK_RESP" | tail -n1)
BATCH_REF=$(echo "$BULK_BODY" | jq -r '.data.batch_reference')

if [ "$BULK_CODE" = "200" ] && [ "$BATCH_REF" = "BATCH-001" ]; then
  pass "TC-10: Bulk payout BATCH-001 accepted and returned 200 OK"
else
  fail "TC-10: Bulk payout failed (code=${BULK_CODE}, batch_ref=${BATCH_REF})"
fi

# ------------------------------------------------------------------
# TC-11: Card Charge Scenario - Initiate & Invalid OTP (00000)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-11: Card Charge Scenario - Initiate & Invalid OTP (00000) ---"
CARD_INIT=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/card" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"charge_data": "encrypted_card_payload_simulation"}')
CARD_INIT_BODY=$(echo "$CARD_INIT" | sed '$d')
CARD_INIT_CODE=$(echo "$CARD_INIT" | tail -n1)
CARD_STATUS=$(echo "$CARD_INIT_BODY" | jq -r '.data.status')
CARD_AUTH_MODEL=$(echo "$CARD_INIT_BODY" | jq -r '.data.auth_model')
CARD_TX_REF=$(echo "$CARD_INIT_BODY" | jq -r '.data.transaction_reference')

BAD_OTP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/card/authorize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "transaction_reference": "CARD-SCENARIO-001",
    "authorization": {
      "otp": "00000"
    }
  }')
BAD_OTP_BODY=$(echo "$BAD_OTP" | sed '$d')
BAD_OTP_CODE=$(echo "$BAD_OTP" | tail -n1)
BAD_OTP_STATUS=$(echo "$BAD_OTP_BODY" | jq -r '.status')

if [ "$CARD_INIT_CODE" = "200" ] && [ "$CARD_STATUS" = "processing" ] && [ "$CARD_AUTH_MODEL" = "OTP" ] && \
   [ "$CARD_TX_REF" = "CARD-SCENARIO-001" ] && [ "$BAD_OTP_CODE" = "400" ] && [ "$BAD_OTP_STATUS" = "false" ]; then
  pass "TC-11: Card charge initiated (Pending_OTP) and invalid OTP 00000 rejected with 400"
else
  fail "TC-11: Card scenario step 1/invalid OTP failed (init=${CARD_INIT_CODE}/${CARD_STATUS}, bad_otp=${BAD_OTP_CODE}/${BAD_OTP_STATUS})"
fi

# ------------------------------------------------------------------
# TC-12: Card Charge Scenario - Valid OTP (12345) & Final Verification
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-12: Card Charge Scenario - Valid OTP (12345) & Verification ---"
GOOD_OTP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/card/authorize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "transaction_reference": "CARD-SCENARIO-001",
    "authorization": {
      "otp": "12345"
    }
  }')
GOOD_OTP_BODY=$(echo "$GOOD_OTP" | sed '$d')
GOOD_OTP_CODE=$(echo "$GOOD_OTP" | tail -n1)
GOOD_OTP_STATUS=$(echo "$GOOD_OTP_BODY" | jq -r '.data.status')

CARD_VERIFY=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/CARD-SCENARIO-001")
CARD_VERIFY_BODY=$(echo "$CARD_VERIFY" | sed '$d')
CARD_VERIFY_CODE=$(echo "$CARD_VERIFY" | tail -n1)
CARD_VERIFY_STATUS=$(echo "$CARD_VERIFY_BODY" | jq -r '.data.status')

if [ "$GOOD_OTP_CODE" = "200" ] && [ "$GOOD_OTP_STATUS" = "success" ] && \
   [ "$CARD_VERIFY_CODE" = "200" ] && [ "$CARD_VERIFY_STATUS" = "success" ]; then
  pass "TC-12: Card charge authorized with valid OTP 12345 and verified as 'success'"
else
  fail "TC-12: Card scenario valid OTP/verify failed (auth=${GOOD_OTP_CODE}/${GOOD_OTP_STATUS}, verify=${CARD_VERIFY_CODE}/${CARD_VERIFY_STATUS})"
fi

# ------------------------------------------------------------------
# TC-13: Payout Polling Scenario (Started -> Processing -> Completed)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-13: Payout Polling Scenario (PAYOUT-SCENARIO-001) ---"
P_INIT=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/transactions/disburse" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "PAYOUT-SCENARIO-001",
    "destination": {
      "type": "bank_account",
      "amount": 75000,
      "currency": "NGN",
      "narration": "Scenario Vendor Payout",
      "bank_account": { "bank": "033", "account": "2158634852" },
      "customer": { "name": "Scenario Beneficiary", "email": "vendor@kora.test" }
    }
  }')
P_INIT_BODY=$(echo "$P_INIT" | sed '$d')
P_INIT_CODE=$(echo "$P_INIT" | tail -n1)
P_INIT_STATUS=$(echo "$P_INIT_BODY" | jq -r '.data.status')

POLL_1=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/PAYOUT-SCENARIO-001")
POLL_1_BODY=$(echo "$POLL_1" | sed '$d')
POLL_1_STATUS=$(echo "$POLL_1_BODY" | jq -r '.data.status')

POLL_2=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/PAYOUT-SCENARIO-001")
POLL_2_BODY=$(echo "$POLL_2" | sed '$d')
POLL_2_STATUS=$(echo "$POLL_2_BODY" | jq -r '.data.status')

if [ "$P_INIT_CODE" = "200" ] && [ "$P_INIT_STATUS" = "processing" ] && \
   [ "$POLL_1_STATUS" = "processing" ] && [ "$POLL_2_STATUS" = "success" ]; then
  pass "TC-13: Payout polling transitioned Started -> Processing (poll 1) -> Completed/success (poll 2)"
else
  fail "TC-13: Payout polling failed (init=${P_INIT_STATUS}, poll1=${POLL_1_STATUS}, poll2=${POLL_2_STATUS})"
fi

# ------------------------------------------------------------------
# TC-14: Refund & Merchant Balance Scenario + Refund State Verification
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-14: Refund & Merchant Balance Scenario ---"
BAL_BEFORE=$(curl -s -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/balances" | jq -r '.data.NGN.available_balance')

REF_INIT=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/refunds/initiate" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "REFUND-SCENARIO-001",
    "payment_reference": "KPY-ORIG-001",
    "amount": 50000,
    "currency": "NGN",
    "reason": "Order cancelled"
  }')
REF_INIT_CODE=$(echo "$REF_INIT" | tail -n1)

BAL_AFTER=$(curl -s -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/balances" | jq -r '.data.NGN.available_balance')

REF_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/refunds/REFUND-SCENARIO-001")
REF_GET_BODY=$(echo "$REF_GET" | sed '$d')
REF_GET_CODE=$(echo "$REF_GET" | tail -n1)
REF_GET_ID=$(echo "$REF_GET_BODY" | jq -r '.data.refund_reference')

if [ "$BAL_BEFORE" = "500000" ] && [ "$REF_INIT_CODE" = "200" ] && \
   [ "$BAL_AFTER" = "450000" ] && [ "$REF_GET_CODE" = "200" ] && [ "$REF_GET_ID" = "REFUND-SCENARIO-001" ]; then
  pass "TC-14: Balance transitioned 500000 -> 450000 on refund and GET /refunds/REFUND-SCENARIO-001 succeeded"
else
  fail "TC-14: Refund/Balance scenario failed (before=${BAL_BEFORE}, after=${BAL_AFTER}, ref_get=${REF_GET_CODE}/${REF_GET_ID})"
fi

# ------------------------------------------------------------------
# TC-15: Idempotency / Duplicate Reference Protection Scenario
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-15: Idempotency & Duplicate Reference Scenario ---"
IDEM_1=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/initialize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 10000,
    "currency": "NGN",
    "reference": "IDEMPOTENT-REF-001",
    "customer": { "name": "Idem User", "email": "idem@kora.test" }
  }')
IDEM_1_CODE=$(echo "$IDEM_1" | tail -n1)

IDEM_2=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/initialize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "amount": 10000,
    "currency": "NGN",
    "reference": "IDEMPOTENT-REF-001",
    "customer": { "name": "Idem User", "email": "idem@kora.test" }
  }')
IDEM_2_BODY=$(echo "$IDEM_2" | sed '$d')
IDEM_2_CODE=$(echo "$IDEM_2" | tail -n1)
IDEM_2_STATUS=$(echo "$IDEM_2_BODY" | jq -r '.status')

if [ "$IDEM_1_CODE" = "200" ] && [ "$IDEM_2_CODE" = "400" ] && [ "$IDEM_2_STATUS" = "false" ]; then
  pass "TC-15: First submission of IDEMPOTENT-REF-001 returned 200; duplicate returned 400 Bad Request"
else
  fail "TC-15: Idempotency scenario failed (first=${IDEM_1_CODE}, second=${IDEM_2_CODE}/${IDEM_2_STATUS})"
fi

# ------------------------------------------------------------------
# TC-16: Misc Banks List & Resolve Bank Account
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-16: Misc Banks List & Resolve Bank Account ---"
BANKS_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/misc/banks")
BANKS_BODY=$(echo "$BANKS_RESP" | sed '$d')
BANKS_CODE=$(echo "$BANKS_RESP" | tail -n1)
BANKS_LEN=$(echo "$BANKS_BODY" | jq '.data | length')

RESOLVE_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/misc/banks/resolve" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"bank": "033", "account": "2158634852"}')
RESOLVE_BODY=$(echo "$RESOLVE_RESP" | sed '$d')
RESOLVE_CODE=$(echo "$RESOLVE_RESP" | tail -n1)
ACC_NAME=$(echo "$RESOLVE_BODY" | jq -r '.data.account_name')

if [ "$BANKS_CODE" = "200" ] && [ "$BANKS_LEN" -gt 0 ] && \
   [ "$RESOLVE_CODE" = "200" ] && [ "$ACC_NAME" = "EBUKA CIROMA OLADEMJI" ]; then
  pass "TC-16: GET /misc/banks (${BANKS_LEN} banks) and POST /misc/banks/resolve verified"
else
  fail "TC-16: Misc banks failed (list=${BANKS_CODE}/${BANKS_LEN}, resolve=${RESOLVE_CODE}/${ACC_NAME})"
fi

# ------------------------------------------------------------------
# TC-17: Card Resend OTP & Mobile Money Authorize / Resend OTP
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-17: Card Resend OTP & Mobile Money Authorize / Resend OTP ---"
CARD_RESEND=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/card/resend-otp" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"transaction_reference": "CARD-SCENARIO-001"}')
CARD_RESEND_CODE=$(echo "$CARD_RESEND" | tail -n1)

MM_AUTH=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/mobile-money/authorize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"transaction_reference": "KORA-MOMO-001", "authorization": {"otp": "123456"}}')
MM_AUTH_BODY=$(echo "$MM_AUTH" | sed '$d')
MM_AUTH_CODE=$(echo "$MM_AUTH" | tail -n1)
MM_AUTH_STATUS=$(echo "$MM_AUTH_BODY" | jq -r '.data.status')

MM_RESEND=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/mobile-money/resend-otp" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"transaction_reference": "KORA-MOMO-001"}')
MM_RESEND_CODE=$(echo "$MM_RESEND" | tail -n1)

if [ "$CARD_RESEND_CODE" = "200" ] && [ "$MM_AUTH_CODE" = "200" ] && [ "$MM_AUTH_STATUS" = "success" ] && [ "$MM_RESEND_CODE" = "200" ]; then
  pass "TC-17: Card resend-otp and Mobile Money authorize & resend-otp returned 200 OK"
else
  fail "TC-17: OTP endpoints failed (card_resend=${CARD_RESEND_CODE}, mm_auth=${MM_AUTH_CODE}/${MM_AUTH_STATUS}, mm_resend=${MM_RESEND_CODE})"
fi

# ------------------------------------------------------------------
# TC-18: Pay With Bank Charge -> Authorize -> Query Charge Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-18: Pay With Bank Charge -> Authorize -> Query Charge Round-Trip ---"
PWB_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/pay-with-bank" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "PWB-DYN-001",
    "amount": 18000,
    "currency": "NGN",
    "bank_code": "058",
    "customer": { "name": "PWB User", "email": "pwb@kora.test" }
  }')
PWB_CODE=$(echo "$PWB_RESP" | tail -n1)

PWB_AUTH=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/pay-with-bank/authorize" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"transaction_reference": "PWB-DYN-001"}')
PWB_AUTH_CODE=$(echo "$PWB_AUTH" | tail -n1)

PWB_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/PWB-DYN-001")
PWB_GET_BODY=$(echo "$PWB_GET" | sed '$d')
PWB_GET_CODE=$(echo "$PWB_GET" | tail -n1)
PWB_METHOD=$(echo "$PWB_GET_BODY" | jq -r '.data.payment_method')

if [ "$PWB_CODE" = "200" ] && [ "$PWB_AUTH_CODE" = "200" ] && [ "$PWB_GET_CODE" = "200" ] && [ "$PWB_METHOD" = "pay_with_bank" ]; then
  pass "TC-18: Pay With Bank PWB-DYN-001 initiated, authorized, and verified via GET /charges/PWB-DYN-001"
else
  fail "TC-18: Pay With Bank failed (post=${PWB_CODE}, auth=${PWB_AUTH_CODE}, get=${PWB_GET_CODE}, method=${PWB_METHOD})"
fi

# ------------------------------------------------------------------
# TC-19: Pay With Bank Supported Banks
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-19: Pay With Bank Supported Banks ---"
PWBB_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/pay-with-bank/banks")
PWBB_BODY=$(echo "$PWBB_RESP" | sed '$d')
PWBB_CODE=$(echo "$PWBB_RESP" | tail -n1)
PWBB_LEN=$(echo "$PWBB_BODY" | jq '.data | length')

if [ "$PWBB_CODE" = "200" ] && [ "$PWBB_LEN" -gt 0 ]; then
  pass "TC-19: GET /charges/pay-with-bank/banks returned ${PWBB_LEN} banks"
else
  fail "TC-19: GET /charges/pay-with-bank/banks failed (code=${PWBB_CODE}, len=${PWBB_LEN})"
fi

# ------------------------------------------------------------------
# TC-20: EFT Charge -> Query Charge Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-20: EFT Charge -> Query Charge Round-Trip ---"
EFT_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/eft" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "reference": "EFT-DYN-001",
    "amount": 1200,
    "currency": "ZAR",
    "customer": { "name": "SA Customer", "email": "zar@kora.test" }
  }')
EFT_CODE=$(echo "$EFT_RESP" | tail -n1)

EFT_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/EFT-DYN-001")
EFT_GET_BODY=$(echo "$EFT_GET" | sed '$d')
EFT_GET_CODE=$(echo "$EFT_GET" | tail -n1)
EFT_CURR=$(echo "$EFT_GET_BODY" | jq -r '.data.currency')
EFT_METHOD=$(echo "$EFT_GET_BODY" | jq -r '.data.payment_method')

if [ "$EFT_CODE" = "200" ] && [ "$EFT_GET_CODE" = "200" ] && [ "$EFT_CURR" = "ZAR" ] && [ "$EFT_METHOD" = "eft" ]; then
  pass "TC-20: EFT charge EFT-DYN-001 persisted and verified via GET /charges/EFT-DYN-001"
else
  fail "TC-20: EFT round-trip failed (post=${EFT_CODE}, get=${EFT_GET_CODE}, curr=${EFT_CURR}, method=${EFT_METHOD})"
fi

# ------------------------------------------------------------------
# TC-21: List Charges (GET /charges and GET /pay-ins)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-21: List Charges (GET /charges & GET /pay-ins) ---"
CHGS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges")
PAYINS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/pay-ins")

if [ "$CHGS_CODE" = "200" ] && [ "$PAYINS_CODE" = "200" ]; then
  pass "TC-21: GET /charges and GET /pay-ins returned 200 OK"
else
  fail "TC-21: List charges failed (charges=${CHGS_CODE}, pay-ins=${PAYINS_CODE})"
fi

# ------------------------------------------------------------------
# TC-22: Stateful Virtual Bank Account Create -> Fetch Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-22: Stateful Virtual Bank Account Create -> Fetch Round-Trip ---"
VBA_POST=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/virtual-bank-account" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "account_name": "Acme Merchant VBA",
    "account_reference": "VBA-REF-001",
    "permanent": true,
    "bank_code": "070",
    "customer": { "name": "Acme Corp", "email": "acme@kora.test" }
  }')
VBA_POST_CODE=$(echo "$VBA_POST" | tail -n1)

VBA_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/virtual-bank-account/VBA-REF-001")
VBA_GET_BODY=$(echo "$VBA_GET" | sed '$d')
VBA_GET_CODE=$(echo "$VBA_GET" | tail -n1)
VBA_NAME=$(echo "$VBA_GET_BODY" | jq -r '.data.account_name')
VBA_REF=$(echo "$VBA_GET_BODY" | jq -r '.data.account_reference')

if [ "$VBA_POST_CODE" = "200" ] && [ "$VBA_GET_CODE" = "200" ] && [ "$VBA_NAME" = "Acme Merchant VBA" ] && [ "$VBA_REF" = "VBA-REF-001" ]; then
  pass "TC-22: Virtual Bank Account VBA-REF-001 created and verified via GET /virtual-bank-account/VBA-REF-001"
else
  fail "TC-22: VBA round-trip failed (post=${VBA_POST_CODE}, get=${VBA_GET_CODE}, name=${VBA_NAME}, ref=${VBA_REF})"
fi

# ------------------------------------------------------------------
# TC-23: Unknown Virtual Bank Account Reference Returns 404
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-23: Unknown Virtual Bank Account Reference Returns 404 ---"
VBA_404=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/virtual-bank-account/UNKNOWN-VBA-999")
if [ "$VBA_404" = "404" ]; then
  pass "TC-23: Unknown Virtual Bank Account UNKNOWN-VBA-999 returned 404 Not Found"
else
  fail "TC-23: Expected 404 for unknown VBA, got ${VBA_404}"
fi

# ------------------------------------------------------------------
# TC-24: Virtual Bank Account Transactions & Sandbox Credit
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-24: Virtual Bank Account Transactions & Sandbox Credit ---"
VBA_TX_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/virtual-bank-account/transactions?account_number=0657789765")
VBA_TX_BODY=$(echo "$VBA_TX_RESP" | sed '$d')
VBA_TX_CODE=$(echo "$VBA_TX_RESP" | tail -n1)
VBA_TX_ACC=$(echo "$VBA_TX_BODY" | jq -r '.data.account_number')

VBA_CRED_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/virtual-bank-account/sandbox/credit" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"account_number": "0657789765", "amount": 25000, "currency": "NGN"}')
VBA_CRED_CODE=$(echo "$VBA_CRED_RESP" | tail -n1)

if [ "$VBA_TX_CODE" = "200" ] && [ "$VBA_TX_ACC" = "0657789765" ] && [ "$VBA_CRED_CODE" = "200" ]; then
  pass "TC-24: GET /virtual-bank-account/transactions and POST /virtual-bank-account/sandbox/credit succeeded"
else
  fail "TC-24: VBA transactions/sandbox credit failed (tx=${VBA_TX_CODE}/${VBA_TX_ACC}, credit=${VBA_CRED_CODE})"
fi

# ------------------------------------------------------------------
# TC-25: Stateful Bulk Payout Batch Fetch & Items List
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-25: Stateful Bulk Payout Batch Fetch & Items List ---"
BULK_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/bulk/BATCH-001")
BULK_GET_BODY=$(echo "$BULK_GET" | sed '$d')
BULK_GET_CODE=$(echo "$BULK_GET" | tail -n1)
BULK_GET_REF=$(echo "$BULK_GET_BODY" | jq -r '.data.batch_reference')

BULK_ITEMS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/bulk/BATCH-001/payout")
BULK_404_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions/bulk/NON-EXISTENT-BATCH")

if [ "$BULK_GET_CODE" = "200" ] && [ "$BULK_GET_REF" = "BATCH-001" ] && [ "$BULK_ITEMS_CODE" = "200" ] && [ "$BULK_404_CODE" = "404" ]; then
  pass "TC-25: Stateful GET /transactions/bulk/BATCH-001 (200), /payout items (200), and unknown batch (404) verified"
else
  fail "TC-25: Bulk batch query failed (get=${BULK_GET_CODE}/${BULK_GET_REF}, items=${BULK_ITEMS_CODE}, 404=${BULK_404_CODE})"
fi

# ------------------------------------------------------------------
# TC-26: List Payout Transactions (GET /transactions & GET /payouts)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-26: List Payout Transactions (GET /transactions & GET /payouts) ---"
TXS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/transactions")
PAYOUTS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/payouts")

if [ "$TXS_CODE" = "200" ] && [ "$PAYOUTS_CODE" = "200" ]; then
  pass "TC-26: GET /transactions and GET /payouts returned 200 OK"
else
  fail "TC-26: List transactions failed (transactions=${TXS_CODE}, payouts=${PAYOUTS_CODE})"
fi

# ------------------------------------------------------------------
# TC-27: List Refunds (GET /refunds)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-27: List Refunds (GET /refunds) ---"
REFUNDS_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/refunds")
if [ "$REFUNDS_CODE" = "200" ]; then
  pass "TC-27: GET /refunds returned 200 OK"
else
  fail "TC-27: GET /refunds returned ${REFUNDS_CODE}"
fi

# ------------------------------------------------------------------
# TC-28: Balance History (GET /balances/history)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-28: Balance History (GET /balances/history) ---"
BAL_HIST_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/balances/history")
BAL_HIST_BODY=$(echo "$BAL_HIST_RESP" | sed '$d')
BAL_HIST_CODE=$(echo "$BAL_HIST_RESP" | tail -n1)
BAL_HIST_LEN=$(echo "$BAL_HIST_BODY" | jq '.data | length')

if [ "$BAL_HIST_CODE" = "200" ] && [ "$BAL_HIST_LEN" -gt 0 ]; then
  pass "TC-28: GET /balances/history returned ${BAL_HIST_LEN} ledger entries"
else
  fail "TC-28: GET /balances/history failed (code=${BAL_HIST_CODE}, len=${BAL_HIST_LEN})"
fi

# ------------------------------------------------------------------
# TC-29: Settlements List & Fetch by Reference
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-29: Settlements List & Fetch by Reference ---"
STL_LIST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/settlements")
STL_GET_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/settlements/STL-2025-001")
STL_GET_BODY=$(echo "$STL_GET_RESP" | sed '$d')
STL_GET_CODE=$(echo "$STL_GET_RESP" | tail -n1)
STL_REF=$(echo "$STL_GET_BODY" | jq -r '.data.reference')

if [ "$STL_LIST_CODE" = "200" ] && [ "$STL_GET_CODE" = "200" ] && [ "$STL_REF" = "STL-2025-001" ]; then
  pass "TC-29: GET /settlements and GET /settlements/STL-2025-001 returned 200 OK"
else
  fail "TC-29: Settlements failed (list=${STL_LIST_CODE}, get=${STL_GET_CODE}/${STL_REF})"
fi

# ------------------------------------------------------------------
# TC-30: Mobile Money Operators List & Resolve Mobile Money
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-30: Mobile Money Operators List & Resolve Mobile Money ---"
MMO_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/misc/mobile-money/operators")
MMO_BODY=$(echo "$MMO_RESP" | sed '$d')
MMO_CODE=$(echo "$MMO_RESP" | tail -n1)
MMO_LEN=$(echo "$MMO_BODY" | jq '.data | length')

MMR_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/misc/mobile-money/resolve" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"phoneNumber": "0241234567", "mobileMoneyCode": "mtn-gh"}')
MMR_BODY=$(echo "$MMR_RESP" | sed '$d')
MMR_CODE=$(echo "$MMR_RESP" | tail -n1)
MMR_NAME=$(echo "$MMR_BODY" | jq -r '.data.account_name')

if [ "$MMO_CODE" = "200" ] && [ "$MMO_LEN" -gt 0 ] && [ "$MMR_CODE" = "200" ] && [ "$MMR_NAME" = "KWAME MENSAH" ]; then
  pass "TC-30: GET /misc/mobile-money/operators (${MMO_LEN} operators) and POST /misc/mobile-money/resolve verified"
else
  fail "TC-30: Mobile money misc failed (list=${MMO_CODE}/${MMO_LEN}, resolve=${MMR_CODE}/${MMR_NAME})"
fi

# ------------------------------------------------------------------
# TC-31: FX Conversion Rates & Execute Conversion
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-31: FX Conversion Rates & Execute Conversion ---"
FXR_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/conversions/rates?from=USD&to=NGN")
FXR_BODY=$(echo "$FXR_RESP" | sed '$d')
FXR_CODE=$(echo "$FXR_RESP" | tail -n1)
FXR_FROM=$(echo "$FXR_BODY" | jq -r '.data.from_currency')

FXC_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/conversions" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"reference": "CONV-TEST-001", "from_currency": "USD", "to_currency": "NGN", "amount": 100}')
FXC_BODY=$(echo "$FXC_RESP" | sed '$d')
FXC_CODE=$(echo "$FXC_RESP" | tail -n1)
FXC_REF=$(echo "$FXC_BODY" | jq -r '.data.reference')

if [ "$FXR_CODE" = "200" ] && [ "$FXR_FROM" = "USD" ] && [ "$FXC_CODE" = "200" ] && [ "$FXC_REF" = "CONV-TEST-001" ]; then
  pass "TC-31: GET /conversions/rates and POST /conversions returned 200 OK"
else
  fail "TC-31: FX conversions failed (rates=${FXR_CODE}/${FXR_FROM}, convert=${FXC_CODE}/${FXC_REF})"
fi

# ------------------------------------------------------------------
# TC-32: Identity Consent Validation Guard (400 Bad Request)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-32: Identity Consent Validation Guard (400 Bad Request) ---"
CONSENT_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/bvn" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{"id": "11111111111", "verification_consent": false}')
CONSENT_BODY=$(echo "$CONSENT_RESP" | sed '$d')
CONSENT_CODE=$(echo "$CONSENT_RESP" | tail -n1)
CONSENT_STATUS=$(echo "$CONSENT_BODY" | jq -r '.status')

if [ "$CONSENT_CODE" = "400" ] && [ "$CONSENT_STATUS" = "false" ]; then
  pass "TC-32: verification_consent=false rejected with 400 Bad Request"
else
  fail "TC-32: Consent guard failed (code=${CONSENT_CODE}, status=${CONSENT_STATUS})"
fi

# ------------------------------------------------------------------
# TC-33: Nigeria BVN Verification -> Stateful Verification Query Round-Trip
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-33: Nigeria BVN Verification -> Stateful Verification Query Round-Trip ---"
BVN_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/bvn" \
  -H "${AUTH_HEADER}" \
  -H "Content-Type: application/json" \
  -d '{
    "id": "11111111111",
    "verification_consent": true,
    "first_name": "Trevor",
    "last_name": "Mandela"
  }')
BVN_BODY=$(echo "$BVN_RESP" | sed '$d')
BVN_CODE=$(echo "$BVN_RESP" | tail -n1)
BVN_REF=$(echo "$BVN_BODY" | jq -r '.data.reference')

BVN_GET=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/identities/verifications/VR-BVN-11111111111")
BVN_GET_BODY=$(echo "$BVN_GET" | sed '$d')
BVN_GET_CODE=$(echo "$BVN_GET" | tail -n1)
BVN_GET_ID=$(echo "$BVN_GET_BODY" | jq -r '.data.id')

if [ "$BVN_CODE" = "200" ] && [ "$BVN_REF" = "VR-BVN-11111111111" ] && \
   [ "$BVN_GET_CODE" = "200" ] && [ "$BVN_GET_ID" = "11111111111" ]; then
  pass "TC-33: Nigeria BVN 11111111111 verified and retrieved via GET /identities/verifications/VR-BVN-11111111111"
else
  fail "TC-33: BVN round-trip failed (post=${BVN_CODE}/${BVN_REF}, get=${BVN_GET_CODE}/${BVN_GET_ID})"
fi

# ------------------------------------------------------------------
# TC-34: Nigeria NIN, vNIN, and Phone Verification
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-34: Nigeria NIN, vNIN, and Phone Verification ---"
NIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/nin" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "22222222222", "verification_consent": true}')
VNIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/vnin" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "AA123456789012BB", "verification_consent": true}')
PHN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/phone" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "08031234567", "verification_consent": true}')

if [ "$NIN_CODE" = "200" ] && [ "$VNIN_CODE" = "200" ] && [ "$PHN_CODE" = "200" ]; then
  pass "TC-34: Nigeria NIN, vNIN, and Phone verification returned 200 OK"
else
  fail "TC-34: Nigeria NIN/vNIN/Phone failed (nin=${NIN_CODE}, vnin=${VNIN_CODE}, phone=${PHN_CODE})"
fi

# ------------------------------------------------------------------
# TC-35: Nigeria Bank Account, Driver's License, Voter's Card, and Passport KYC
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-35: Nigeria Bank Account, Driver's License, Voter's Card & Passport KYC ---"
NBA_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/bank-account" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"account_number": "2158634852", "bank_code": "033", "verification_consent": true}')
NDL_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/drivers-license" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "FKJ12345AA01", "verification_consent": true}')
NVC_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/voters-card" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "90F5B1234567890", "verification_consent": true}')
NPP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/passport" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "A12345678", "verification_consent": true}')

if [ "$NBA_CODE" = "200" ] && [ "$NDL_CODE" = "200" ] && [ "$NVC_CODE" = "200" ] && [ "$NPP_CODE" = "200" ]; then
  pass "TC-35: Nigeria Bank Account, Driver's License, Voter's Card, and Passport KYC returned 200 OK"
else
  fail "TC-35: Nigeria civil IDs failed (ba=${NBA_CODE}, dl=${NDL_CODE}, vc=${NVC_CODE}, pp=${NPP_CODE})"
fi

# ------------------------------------------------------------------
# TC-36: Nigeria Business KYB (CAC & TIN) -> Stateful Verification Query
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-36: Nigeria Business KYB (CAC & TIN) ---"
CAC_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/cac" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "1492819", "registration_type": "RC", "verification_consent": true}')
CAC_BODY=$(echo "$CAC_RESP" | sed '$d')
CAC_CODE=$(echo "$CAC_RESP" | tail -n1)
CAC_COMP=$(echo "$CAC_BODY" | jq -r '.data.company_name')

TIN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/tin" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "12345678-0001", "verification_consent": true}')

CAC_GET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/identities/verifications/VR-CAC-1492819")

if [ "$CAC_CODE" = "200" ] && [ "$CAC_COMP" = "KORA PAYMENTS LIMITED" ] && [ "$TIN_CODE" = "200" ] && [ "$CAC_GET_CODE" = "200" ]; then
  pass "TC-36: Nigeria CAC & TIN KYB verified and VR-CAC-1492819 retrieved via state-matcher"
else
  fail "TC-36: Nigeria KYB failed (cac=${CAC_CODE}/${CAC_COMP}, tin=${TIN_CODE}, get=${CAC_GET_CODE})"
fi

# ------------------------------------------------------------------
# TC-37: Kenya KYC (National ID, KRA PIN, Passport)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-37: Kenya KYC (National ID, KRA PIN, Passport) ---"
KE_ID_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ke/national-id" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "12345678", "verification_consent": true}')
KE_KRA_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ke/kra-pin" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "A001234567Z", "verification_consent": true}')
KE_PP_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ke/passport" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "AK123456", "verification_consent": true}')

if [ "$KE_ID_CODE" = "200" ] && [ "$KE_KRA_CODE" = "200" ] && [ "$KE_PP_CODE" = "200" ]; then
  pass "TC-37: Kenya National ID, KRA PIN, and Passport KYC returned 200 OK"
else
  fail "TC-37: Kenya KYC failed (id=${KE_ID_CODE}, kra=${KE_KRA_CODE}, pp=${KE_PP_CODE})"
fi

# ------------------------------------------------------------------
# TC-38: Ghana KYC (Ghana Card, SSNIT, Voter's Card)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-38: Ghana KYC (Ghana Card, SSNIT, Voter's Card) ---"
GH_CARD_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/gh/ghana-card" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "GHA-123456789-0", "verification_consent": true}')
GH_SSNIT_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/gh/ssnit" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "C001234567890", "verification_consent": true}')
GH_VC_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/gh/voters-card" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "2345678901", "verification_consent": true}')

if [ "$GH_CARD_CODE" = "200" ] && [ "$GH_SSNIT_CODE" = "200" ] && [ "$GH_VC_CODE" = "200" ]; then
  pass "TC-38: Ghana Card, SSNIT, and Voter's Card KYC returned 200 OK"
else
  fail "TC-38: Ghana KYC failed (card=${GH_CARD_CODE}, ssnit=${GH_SSNIT_CODE}, vc=${GH_VC_CODE})"
fi

# ------------------------------------------------------------------
# TC-39: South Africa KYC (Smart National ID)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-39: South Africa KYC (Smart National ID) ---"
ZA_RESP=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/za/national-id" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "8907085000081", "verification_consent": true}')
ZA_BODY=$(echo "$ZA_RESP" | sed '$d')
ZA_CODE=$(echo "$ZA_RESP" | tail -n1)
ZA_COUNTRY=$(echo "$ZA_BODY" | jq -r '.data.country')

if [ "$ZA_CODE" = "200" ] && [ "$ZA_COUNTRY" = "ZA" ]; then
  pass "TC-39: South Africa Smart National ID verified (country=ZA)"
else
  fail "TC-39: South Africa KYC failed (code=${ZA_CODE}, country=${ZA_COUNTRY})"
fi

# ------------------------------------------------------------------
# TC-40: Dual-Prefix Compatibility (/api/v1/identities/...)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-40: Dual-Prefix Compatibility (/api/v1/identities/...) ---"
ALT_BVN_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/api/v1/identities/ng/bvn" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "99999999999", "verification_consent": true}')
ALT_GET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/api/v1/identities/verifications/VR-BVN-99999999999")

if [ "$ALT_BVN_CODE" = "200" ] && [ "$ALT_GET_CODE" = "200" ]; then
  pass "TC-40: /api/v1/identities/... dual-prefix POST and stateful GET verified"
else
  fail "TC-40: Dual-prefix test failed (post=${ALT_BVN_CODE}, get=${ALT_GET_CODE})"
fi

# ------------------------------------------------------------------
# TC-41: Unknown Verification Reference Returns 404
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-41: Unknown Verification Reference Returns 404 ---"
VR_404=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/identities/verifications/VR-NON-EXISTENT-999")
if [ "$VR_404" = "404" ]; then
  pass "TC-41: Unknown verification reference VR-NON-EXISTENT-999 returned 404 Not Found"
else
  fail "TC-41: Expected 404 for unknown verification reference, got ${VR_404}"
fi

# ------------------------------------------------------------------
# TC-42: Verification History & Document Verification
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-42: Verification History & Document Verification ---"
VH_GET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/identities/verifications")
VH_POST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/verifications" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d '{}')
VDOC_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/verifications/documents" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d '{"document_type": "passport"}')

if [ "$VH_GET_CODE" = "200" ] && [ "$VH_POST_CODE" = "200" ] && [ "$VDOC_CODE" = "200" ]; then
  pass "TC-42: Verification history (GET/POST) and document verification returned 200 OK"
else
  fail "TC-42: History/document verification failed (get=${VH_GET_CODE}, post=${VH_POST_CODE}, doc=${VDOC_CODE})"
fi

# ------------------------------------------------------------------
# TC-43: Identity Verification Lifecycle Scenario - Step 1 (Pending_Consent)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-43: Identity Verification Lifecycle Scenario - Step 1 (Pending_Consent) ---"
IDS_1=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/ng/bvn" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"id": "ID-SCENARIO-001", "verification_consent": true}')
IDS_1_BODY=$(echo "$IDS_1" | sed '$d')
IDS_1_CODE=$(echo "$IDS_1" | tail -n1)
IDS_1_STATUS=$(echo "$IDS_1_BODY" | jq -r '.data.status')
IDS_1_REF=$(echo "$IDS_1_BODY" | jq -r '.data.reference')

if [ "$IDS_1_CODE" = "200" ] && [ "$IDS_1_STATUS" = "pending_consent" ] && [ "$IDS_1_REF" = "VR-SCENARIO-001" ]; then
  pass "TC-43: ID-SCENARIO-001 transitioned Started -> Pending_Consent (status=pending_consent)"
else
  fail "TC-43: Identity scenario step 1 failed (code=${IDS_1_CODE}, status=${IDS_1_STATUS}, ref=${IDS_1_REF})"
fi

# ------------------------------------------------------------------
# TC-44: Identity Verification Lifecycle Scenario - Step 2 & 3 (Consent -> Verified)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-44: Identity Verification Lifecycle Scenario - Step 2 & 3 (Verified) ---"
IDS_2=$(curl -s -w "\n%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/identities/verifications/consent" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" \
  -d '{"reference": "VR-SCENARIO-001", "otp": "123456"}')
IDS_2_BODY=$(echo "$IDS_2" | sed '$d')
IDS_2_CODE=$(echo "$IDS_2" | tail -n1)
IDS_2_STATUS=$(echo "$IDS_2_BODY" | jq -r '.data.status')

IDS_3=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/identities/verifications/VR-SCENARIO-001")
IDS_3_BODY=$(echo "$IDS_3" | sed '$d')
IDS_3_CODE=$(echo "$IDS_3" | tail -n1)
IDS_3_STATUS=$(echo "$IDS_3_BODY" | jq -r '.data.status')

if [ "$IDS_2_CODE" = "200" ] && [ "$IDS_2_STATUS" = "verified" ] && [ "$IDS_3_CODE" = "200" ] && [ "$IDS_3_STATUS" = "verified" ]; then
  pass "TC-44: VR-SCENARIO-001 consent confirmed and verified via GET /identities/verifications/VR-SCENARIO-001"
else
  fail "TC-44: Identity scenario step 2/3 failed (consent=${IDS_2_CODE}/${IDS_2_STATUS}, get=${IDS_3_CODE}/${IDS_3_STATUS})"
fi

# ------------------------------------------------------------------
# TC-45: Scenario Reset Verification
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-45: Admin Scenarios Reset ---"
RESET_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/__admin/scenarios/reset")
BAL_RESET=$(curl -s -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/balances" | jq -r '.data.NGN.available_balance')

if [ "$RESET_CODE" = "200" ] && [ "$BAL_RESET" = "500000" ]; then
  pass "TC-45: POST /__admin/scenarios/reset restored all 5 scenarios to Started (NGN balance = 500000)"
else
  fail "TC-45: Scenario reset failed (reset_code=${RESET_CODE}, balance=${BAL_RESET})"
fi

# ------------------------------------------------------------------
# TC-46: Automated OpenAPI 3.0.3 Generator Execution
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-46: Automated OpenAPI 3.0.3 Generator Execution ---"
if python3 scripts/generate-openapi.py >/dev/null && \
   [ -s wiremock/__files/openapi.json ] && [ -s wiremock/__files/openapi.yaml ]; then
  pass "TC-46: scripts/generate-openapi.py generated non-empty openapi.json and openapi.yaml"
else
  fail "TC-46: OpenAPI generator script execution failed"
fi

# ------------------------------------------------------------------
# TC-47: OpenAPI 3.0.3 Schema & Coverage Validation
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-47: OpenAPI 3.0.3 Schema & Coverage Validation ---"
OAPI_VER=$(jq -r '.openapi' wiremock/__files/openapi.json)
OAPI_SRV=$(jq -r '.servers[0].url' wiremock/__files/openapi.json)
OAPI_SEC=$(jq -r '.components.securitySchemes.BearerAuth.scheme' wiremock/__files/openapi.json)
OAPI_PATHS=$(jq '.paths | length' wiremock/__files/openapi.json)
OAPI_TAGS=$(jq '.tags | length' wiremock/__files/openapi.json)

if [ "$OAPI_VER" = "3.0.3" ] && [ "$OAPI_SRV" = "http://localhost:8080" ] && \
   [ "$OAPI_SEC" = "bearer" ] && [ "$OAPI_PATHS" -ge 40 ] && [ "$OAPI_TAGS" -ge 10 ]; then
  pass "TC-47: OpenAPI 3.0.3 spec validated (${OAPI_PATHS} paths, ${OAPI_TAGS} tags, BearerAuth scheme)"
else
  fail "TC-47: OpenAPI validation failed (ver=${OAPI_VER}, srv=${OAPI_SRV}, sec=${OAPI_SEC}, paths=${OAPI_PATHS}, tags=${OAPI_TAGS})"
fi

# ------------------------------------------------------------------
# TC-48: Live Server GET /openapi.json & CORS Headers (No Auth Required)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-48: Live Server GET /openapi.json & CORS Headers ---"
OAPI_HEADERS=$(curl -s -D - -o /dev/null "${BASE_URL}/openapi.json")
OAPI_LIVE_VER=$(curl -s "${BASE_URL}/openapi.json" | jq -r '.openapi')
OAPI_ALT_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/api-docs/openapi.json")

if grep -qi "Access-Control-Allow-Origin: \*" <<< "$OAPI_HEADERS" && \
   [ "$OAPI_LIVE_VER" = "3.0.3" ] && [ "$OAPI_ALT_CODE" = "200" ]; then
  pass "TC-48: GET /openapi.json and /api-docs/openapi.json served with CORS headers and openapi=3.0.3"
else
  fail "TC-48: Live /openapi.json failed (ver=${OAPI_LIVE_VER}, alt_code=${OAPI_ALT_CODE})"
fi

# ------------------------------------------------------------------
# TC-49: Live Server GET /openapi.yaml (No Auth Required)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-49: Live Server GET /openapi.yaml ---"
YAML_RESP=$(curl -s -w "\n%{http_code}" "${BASE_URL}/openapi.yaml")
YAML_BODY=$(echo "$YAML_RESP" | sed '$d')
YAML_CODE=$(echo "$YAML_RESP" | tail -n1)

if [ "$YAML_CODE" = "200" ] && grep -Eq 'openapi:.*3\.0\.3' <<< "$YAML_BODY"; then
  pass "TC-49: GET /openapi.yaml returned 200 OK with valid YAML content"
else
  fail "TC-49: GET /openapi.yaml failed (code=${YAML_CODE})"
fi

# ------------------------------------------------------------------
# TC-50: Interactive Swagger UI Portal (GET /docs & GET /swagger)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-50: Interactive Swagger UI Portal (GET /docs & GET /swagger) ---"
DOCS_BODY=$(curl -s "${BASE_URL}/docs")
SWAG_CODE=$(curl -s -o /dev/null -w "%{http_code}" "${BASE_URL}/swagger")

if [ "$SWAG_CODE" = "200" ] && grep -q "SwaggerUIBundle" <<< "$DOCS_BODY" && \
   grep -q "sk_test_kora_stateful_mock_2025" <<< "$DOCS_BODY"; then
  pass "TC-50: GET /docs and GET /swagger served interactive Swagger UI with pre-authorized Bearer key"
else
  fail "TC-50: Swagger UI portal check failed (swagger_code=${SWAG_CODE})"
fi

# ------------------------------------------------------------------
# TC-51: Redoc Reference Documentation Portal (GET /redoc)
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-51: Redoc Reference Documentation Portal (GET /redoc) ---"
REDOC_RESP=$(curl -s -w "\n%{http_code}" "${BASE_URL}/redoc")
REDOC_BODY=$(echo "$REDOC_RESP" | sed '$d')
REDOC_CODE=$(echo "$REDOC_RESP" | tail -n1)

if [ "$REDOC_CODE" = "200" ] && grep -q 'spec-url="/openapi.json"' <<< "$REDOC_BODY"; then
  pass "TC-51: GET /redoc served Redoc reference page linked to /openapi.json"
else
  fail "TC-51: GET /redoc failed (code=${REDOC_CODE})"
fi

# ------------------------------------------------------------------
# TC-52: End-to-End "Try It Out" Simulation Using OpenAPI Spec Example
# ------------------------------------------------------------------
echo ""
echo "--- Running TC-52: End-to-End Swagger 'Try It Out' Simulation ---"
SPEC_EXAMPLE=$(jq -c '.paths["/merchant/api/v1/charges/initialize"].post.requestBody.content["application/json"].example' wiremock/__files/openapi.json)
TRY_REF=$(echo "$SPEC_EXAMPLE" | jq -r '.reference')

TRY_POST_CODE=$(curl -s -o /dev/null -w "%{http_code}" -X POST "${BASE_URL}/merchant/api/v1/charges/initialize" \
  -H "${AUTH_HEADER}" -H "Content-Type: application/json" -d "${SPEC_EXAMPLE}")
TRY_GET_RESP=$(curl -s -w "\n%{http_code}" -H "${AUTH_HEADER}" "${BASE_URL}/merchant/api/v1/charges/${TRY_REF}")
TRY_GET_BODY=$(echo "$TRY_GET_RESP" | sed '$d')
TRY_GET_CODE=$(echo "$TRY_GET_RESP" | tail -n1)
TRY_GET_REF=$(echo "$TRY_GET_BODY" | jq -r '.data.reference')

if [ "$TRY_POST_CODE" = "200" ] && [ "$TRY_GET_CODE" = "200" ] && [ "$TRY_GET_REF" = "$TRY_REF" ]; then
  pass "TC-52: OpenAPI spec example payload (${TRY_REF}) executed and verified statefully"
else
  fail "TC-52: OpenAPI 'Try It Out' simulation failed (post=${TRY_POST_CODE}, get=${TRY_GET_CODE}/${TRY_GET_REF})"
fi

echo ""
echo "================================================================="
echo " Summary: ${PASS_COUNT} Passed, ${FAIL_COUNT} Failed"
echo "================================================================="

[ "$FAIL_COUNT" -eq 0 ] && exit 0 || exit 1
