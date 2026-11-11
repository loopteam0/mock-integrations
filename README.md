# Kora (Korapay) Complete Stateful API Mock Server — Payments, Identity & Interactive OpenAPI Docs

A containerized, stateful mock server for the **complete [Kora Developer API](https://developers.korapay.com/docs/getting-started)** and **[Kora Identity Verification (KYC / KYB) API](https://developers.korapay.com/docs/verify-customers-businesses)** built on **WireMock 3.9.2**, combining:
1. **Interactive OpenAPI 3.0.3 Documentation UI (`/docs` & `/redoc`)**: Built-in **Swagger UI** ("Try It Out" pre-authorized with `Bearer sk_test_kora_stateful_mock_2025`) and **Redoc** 3-column API reference served directly from the WireMock container on port `8080`.
2. **`wiremock-state-extension` + Global Response Templating** for dynamic, reference-indexed persistence across `POST` creation and `GET` verification endpoints (Charges, Bank Transfers, Mobile Money, Pay With Bank, EFT, Virtual Bank Accounts, Single & Bulk Payouts, Refunds, and Identity KYC/KYB Verifications).
3. **WireMock Scenarios (Finite State Machines)** for multi-step payment and identity lifecycles (`Card-Charge-Lifecycle`, `Payout-Lifecycle`, `Refund-Balance-Lifecycle`, `Idempotency-Flow`, and `Identity-Verification-Lifecycle`).

---

## Interactive API Documentation & OpenAPI 3.0.3 Specification

Once the container is running on `http://localhost:8080`, open any of the following URLs in your browser (no authentication header required for doc routes):

| Portal / Spec | URL | Description |
| :--- | :--- | :--- |
| **Interactive Swagger UI** | [`http://localhost:8080/docs`](http://localhost:8080/docs) (or `/swagger`, `/`) | Full interactive API explorer with **"Try it out"** enabled and `Bearer sk_test_kora_stateful_mock_2025` pre-authorized automatically. |
| **Redoc Reference UI** | [`http://localhost:8080/redoc`](http://localhost:8080/redoc) | Clean 3-column developer reference documentation with request/response examples. |
| **OpenAPI 3.0.3 JSON** | [`http://localhost:8080/openapi.json`](http://localhost:8080/openapi.json) | Complete OpenAPI 3.0.3 JSON specification (importable into Postman, Insomnia, or Bruno). |
| **OpenAPI 3.0.3 YAML** | [`http://localhost:8080/openapi.yaml`](http://localhost:8080/openapi.yaml) | Complete OpenAPI 3.0.3 YAML specification. |

To regenerate `wiremock/__files/openapi.json` and `wiremock/__files/openapi.yaml` from the WireMock mappings at any time:
```bash
python3 scripts/generate-openapi.py
```

---

## Architecture & Dual State Mechanism

```
Client Request (Browser / Swagger UI / curl / SDK / Postman)
        │
        ▼
┌───────────────────────────────────────────────────────────────────┐
│ WireMock 3.9.2 Container (:8080)                                  │
│                                                                   │
│  [Public Doc Routes] GET /docs, /redoc, /openapi.json, /openapi.yaml│
│                                                                   │
│  [Priority 1-2] Auth Guards on ^/(merchant/)?api/v1/.*            │
│        │                                                          │
│        ├──► [Priority 3] WireMock Scenarios & Static Sub-paths    │
│        │      • Card-Charge-Lifecycle (Started -> Pending_OTP     │
│        │        -> Succeeded)                                     │
│        │      • Payout-Lifecycle (Started -> Processing           │
│        │        -> Completed)                                     │
│        │      • Refund-Balance-Lifecycle (500,000 -> 450,000 NGN) │
│        │      • Idempotency-Flow (200 OK -> 400 Duplicate Ref)    │
│        │      • Identity-Verification-Lifecycle (Started ->       │
│        │        Pending_Consent -> Verified)                      │
│        │                                                          │
│        ├──► [Priority 4] KYC Consent Guard                        │
│        │      • Rejects verification_consent == false with 400    │
│        │                                                          │
│        ├──► [Priority 5] WireMock State Extension (Dynamic CRUD)  │
│        │      • POST records context={{reference}} via            │
│        │        serveEventListeners ("recordState")               │
│        │      • GET matches context={{request.path.reference}}    │
│        │        via customMatcher ("state-matcher")               │
│        │                                                          │
│        └──► [Priority 10-20] 404 Not Found Fallbacks              │
└───────────────────────────────────────────────────────────────────┘
```

---

## Quick Start

### 1. Start with Docker Compose
```bash
docker compose up -d --build
```

Verify the server is healthy:
```bash
curl -i http://localhost:8080/__admin/health
```

### 2. Run the 52-Test End-to-End Verification Suite
```bash
./tests/verify_kora_mock.sh
```

For offline JSON syntax and mapping structure validation only:
```bash
./tests/verify_kora_mock.sh --offline-only
```

---

## Authentication & Dual-Prefix Support

All `/merchant/api/v1/*` and `/api/v1/*` endpoints require a valid Kora Bearer token matching:
```
Authorization: Bearer sk_test_<your_key>
# or sk_live_*, pk_test_*, pk_live_*
```
Missing or malformed `Authorization` headers immediately return `401 Unauthorized` with `{"status": false, "message": "...", "data": null}`.

---

## Complete Supported Endpoints (60+ Endpoints)

### 1. Payments, Payouts, Settlements & FX
| Category | Method | Endpoint | Behavior |
| :--- | :--- | :--- | :--- |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/initialize` | Records dynamic charge state indexed by `reference` and returns `checkout_url`. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/bank-transfer` | Records dynamic bank-transfer charge state and returns a Wema Bank virtual account. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/mobile-money` | Records dynamic mobile-money charge state (`KES`/`GHS`) and returns `STK_PROMPT`. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/mobile-money/authorize` | Authorizes mobile money OTP/STK prompt and updates stored state to `success`. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/mobile-money/resend-otp` | Resends OTP / STK prompt for a mobile money charge. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/card` | Transitions `Card-Charge-Lifecycle` from `Started` to `Pending_OTP` (`CARD-SCENARIO-001`). |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/card/authorize` | Validates OTP (`00000` -> `400 Bad Request`; `12345` -> `200 OK` & `Succeeded`). |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/card/resend-otp` | Resends card charge OTP. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/pay-with-bank` | Records dynamic Pay-with-Bank charge state and returns `redirect_url`. |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/pay-with-bank/authorize` | Authorizes a Pay-with-Bank charge. |
| **Charges (Pay-ins)** | `GET` | `/merchant/api/v1/charges/pay-with-bank/banks` | Returns Pay-with-Bank supported banks (`pwb-banks.json`). |
| **Charges (Pay-ins)** | `POST` | `/merchant/api/v1/charges/eft` | Records dynamic EFT charge state (`ZAR`) and returns `redirect_url`. |
| **Charges (Pay-ins)** | `GET` | `/merchant/api/v1/charges/{reference}` | Returns stored charge state for `{reference}` or `404 Not Found` if unknown. |
| **Charges (Pay-ins)** | `GET` | `/merchant/api/v1/charges` | Lists charges with pagination. |
| **Charges (Pay-ins)** | `GET` | `/merchant/api/v1/pay-ins` | Alias for listing pay-in charges with pagination. |
| **Virtual Accounts** | `POST` | `/merchant/api/v1/virtual-bank-account` | Creates a permanent Virtual Bank Account and records state under `account_reference`. |
| **Virtual Accounts** | `GET` | `/merchant/api/v1/virtual-bank-account/{account_reference}` | Returns stored Virtual Bank Account by `account_reference` or `404 Not Found`. |
| **Virtual Accounts** | `GET` | `/merchant/api/v1/virtual-bank-account/transactions` | Lists inward transactions for a Virtual Bank Account. |
| **Virtual Accounts** | `POST` | `/merchant/api/v1/virtual-bank-account/sandbox/credit` | Simulates crediting a Virtual Bank Account in sandbox. |
| **Payouts** | `POST` | `/merchant/api/v1/transactions/disburse` | Records dynamic payout state (or starts `Payout-Lifecycle` for `PAYOUT-SCENARIO-001`). |
| **Payouts** | `POST` | `/merchant/api/v1/transactions/disburse/bulk` | Records dynamic bulk payout batch state indexed by `batch_reference`. |
| **Payouts** | `GET` | `/merchant/api/v1/transactions/bulk/{batch_reference}` | Returns stored bulk batch status for `{batch_reference}` or `404 Not Found`. |
| **Payouts** | `GET` | `/merchant/api/v1/transactions/bulk/{batch_reference}/payout` | Lists individual payouts inside a bulk batch. |
| **Payouts** | `GET` | `/merchant/api/v1/transactions/{reference}` | Returns stored payout state (or advances `Payout-Lifecycle` for `PAYOUT-SCENARIO-001`). |
| **Payouts** | `GET` | `/merchant/api/v1/transactions` | Lists payout transactions with pagination. |
| **Payouts** | `GET` | `/merchant/api/v1/payouts` | Alias for listing payouts with pagination. |
| **Refunds** | `POST` | `/merchant/api/v1/refunds/initiate` | Records dynamic refund state and transitions `Refund-Balance-Lifecycle` to `Refunded`. |
| **Refunds** | `GET` | `/merchant/api/v1/refunds/{reference}` | Returns stored refund state for `{reference}` or `404 Not Found`. |
| **Refunds** | `GET` | `/merchant/api/v1/refunds` | Lists refunds with pagination. |
| **Balances & Ledger** | `GET` | `/merchant/api/v1/balances` | Returns `NGN`, `KES`, `GHS`, `USD` balances (`500000` NGN initially, `450000` NGN after refund). |
| **Balances & Ledger** | `GET` | `/merchant/api/v1/balances/history` | Returns merchant wallet balance history / ledger entries. |
| **Settlements** | `GET` | `/merchant/api/v1/settlements` | Lists merchant settlements with pagination. |
| **Settlements** | `GET` | `/merchant/api/v1/settlements/{reference}` | Fetches a specific settlement by `{reference}`. |
| **Verification & FX** | `GET` | `/merchant/api/v1/misc/banks` | Returns list of Nigerian banks (`044`, `058`, `033`, `035`, `057`). |
| **Verification & FX** | `POST` | `/merchant/api/v1/misc/banks/resolve` | Resolves bank account number and bank code to `EBUKA CIROMA OLADEMJI`. |
| **Verification & FX** | `GET` | `/merchant/api/v1/misc/mobile-money/operators` | Lists supported African Mobile Money Operators (`mmo-operators.json`). |
| **Verification & FX** | `POST` | `/merchant/api/v1/misc/mobile-money/resolve` | Resolves a mobile money wallet to `KWAME MENSAH`. |
| **Verification & FX** | `GET` | `/merchant/api/v1/conversions/rates` | Retrieves FX conversion rates (`from` / `to` query params). |
| **Verification & FX** | `POST` | `/merchant/api/v1/conversions` | Executes an FX currency conversion between merchant wallets. |

### 2. Identity Verification (KYC / KYB) — Supports both `/merchant/api/v1/*` and `/api/v1/*`
| Country / Scope | Method | Endpoint | Behavior |
| :--- | :--- | :--- | :--- |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/bvn` | Verifies BVN, records state under `VR-BVN-{{id}}`, supports `facial_match` and `ID-SCENARIO-001`. |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/nin` | Verifies NIN and records state under `VR-NIN-{{id}}`. |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/vnin` | Verifies Virtual NIN (vNIN) and records state under `VR-VNIN-{{id}}`. |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/phone` | Verifies Nigerian phone number and records state under `VR-PHN-{{id}}`. |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/bank-account` | Verifies Nigerian bank account + BVN linkage (`VR-BA-{{account_number}}`). |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/drivers-license` | Verifies FRSC Driver's License (`VR-DL-{{id}}`). |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/voters-card` | Verifies INEC Voter's Card / PVC (`VR-VC-{{id}}`). |
| **Nigeria KYC** | `POST` | `/(merchant/)?api/v1/identities/ng/passport` | Verifies Nigerian International Passport (`VR-PP-{{id}}`). |
| **Nigeria KYB** | `POST` | `/(merchant/)?api/v1/identities/ng/cac` | Verifies CAC Business Registration (`RC`/`BN`/`IT`) under `VR-CAC-{{id}}`. |
| **Nigeria KYB** | `POST` | `/(merchant/)?api/v1/identities/ng/tin` | Verifies Corporate Tax Identification Number (`VR-TIN-{{id}}`). |
| **Kenya KYC** | `POST` | `/(merchant/)?api/v1/identities/ke/national-id` | Verifies Kenyan National ID (`VR-KE-ID-{{id}}`). |
| **Kenya KYC** | `POST` | `/(merchant/)?api/v1/identities/ke/kra-pin` | Verifies Kenyan KRA Tax PIN (`VR-KE-KRA-{{id}}`). |
| **Kenya KYC** | `POST` | `/(merchant/)?api/v1/identities/ke/passport` | Verifies Kenyan Passport (`VR-KE-PP-{{id}}`). |
| **Ghana KYC** | `POST` | `/(merchant/)?api/v1/identities/gh/ghana-card` | Verifies Ghana Card / National ID (`VR-GH-CARD-{{id}}`). |
| **Ghana KYC** | `POST` | `/(merchant/)?api/v1/identities/gh/ssnit` | Verifies Ghana SSNIT (`VR-GH-ID-{{id}}`). |
| **Ghana KYC** | `POST` | `/(merchant/)?api/v1/identities/gh/voters-card` | Verifies Ghana Voter's Card (`VR-GH-ID-{{id}}`). |
| **South Africa KYC** | `POST` | `/(merchant/)?api/v1/identities/za/national-id` | Verifies South Africa Smart National ID (`VR-ZA-{{id}}`). |
| **Management** | `GET` | `/(merchant/)?api/v1/identities/verifications/{reference}` | Retrieves stored KYC/KYB verification record by `{reference}` or `404 Not Found`. |
| **Management** | `GET/POST` | `/(merchant/)?api/v1/identities/verifications` | Lists verification history with pagination. |
| **Management** | `POST` | `/(merchant/)?api/v1/identities/verifications/documents` | Performs document authenticity verification (`authenticity_score: 98.2`). |
| **Management** | `POST` | `/(merchant/)?api/v1/identities/verifications/consent` | Completes `Identity-Verification-Lifecycle` (`Pending_Consent` -> `Verified`). |
