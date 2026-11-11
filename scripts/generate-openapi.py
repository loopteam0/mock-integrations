#!/usr/bin/env python3
"""
Automated OpenAPI 3.0.3 Specification Generator for Kora (Korapay) Stateful WireMock Server.
Introspects wiremock/mappings/*.json and generates wiremock/__files/openapi.json and wiremock/__files/openapi.yaml.
Uses only the Python 3 standard library.
"""

import glob
import json
import os
import re
import sys
from typing import Any, Dict, List, Optional


def to_yaml(obj: Any, indent: int = 0) -> str:
    """Pure-Python YAML serializer for JSON-compatible dicts/lists/primitives."""
    sp = "  " * indent
    if obj is None:
        return "null"
    if isinstance(obj, bool):
        return "true" if obj else "false"
    if isinstance(obj, (int, float)):
        return str(obj)
    if isinstance(obj, str):
        if (
            obj == ""
            or any(c in obj for c in [":", "#", "{", "}", "[", "]", ",", "&", "*", "?", "|", "-", "<", ">", "=", "!", "%", "@", "`", "\n", '"', "'"])
            or obj.strip() != obj
            or obj.lower() in ("true", "false", "null", "yes", "no", "on", "off")
            or re.match(r"^[0-9.+-]+$", obj)
        ):
            return json.dumps(obj, ensure_ascii=False)
        return obj
    if isinstance(obj, list):
        if not obj:
            return "[]"
        lines: List[str] = []
        for item in obj:
            if isinstance(item, (dict, list)) and item:
                nested = to_yaml(item, indent + 1)
                first_line, *rest = nested.splitlines()
                lines.append(f"{sp}- {first_line.lstrip()}")
                lines.extend(rest)
            else:
                lines.append(f"{sp}- {to_yaml(item, indent + 1)}")
        return "\n".join(lines)
    if isinstance(obj, dict):
        if not obj:
            return "{}"
        lines = []
        for k, v in obj.items():
            key_str = str(k)
            if any(c in key_str for c in [":", "#", "{", "}", "[", "]", " ", "/"]):
                key_str = json.dumps(key_str, ensure_ascii=False)
            if isinstance(v, (dict, list)) and v:
                lines.append(f"{sp}{key_str}:")
                lines.append(to_yaml(v, indent + 1))
            else:
                lines.append(f"{sp}{key_str}: {to_yaml(v, indent + 1)}")
        return "\n".join(lines)
    return json.dumps(obj)


def introspect_mappings(mappings_dir: str) -> int:
    """Verify and count all WireMock stub mappings in wiremock/mappings/*.json."""
    total_stubs = 0
    for path in sorted(glob.glob(os.path.join(mappings_dir, "*.json"))):
        with open(path, "r", encoding="utf-8") as f:
            data = json.load(f)
        stubs = data.get("mappings", [data])
        total_stubs += len(stubs)
    return total_stubs


def std_responses(success_desc: str, example_data: Any, include_404: bool = False) -> Dict[str, Any]:
    res: Dict[str, Any] = {
        "200": {
            "description": success_desc,
            "content": {
                "application/json": {
                    "schema": {"$ref": "#/components/schemas/KoraStandardResponse"},
                    "example": {
                        "status": True,
                        "message": success_desc,
                        "data": example_data,
                    },
                }
            },
        },
        "400": {"$ref": "#/components/responses/BadRequestError"},
        "401": {"$ref": "#/components/responses/UnauthorizedError"},
    }
    if include_404:
        res["404"] = {"$ref": "#/components/responses/NotFoundError"}
    return res


def post_op(
    tag: str,
    summary: str,
    description: str,
    req_example: Dict[str, Any],
    res_example: Any,
    operation_id: str,
) -> Dict[str, Any]:
    return {
        "tags": [tag],
        "summary": summary,
        "description": description,
        "operationId": operation_id,
        "requestBody": {
            "required": True,
            "content": {
                "application/json": {
                    "schema": {"type": "object"},
                    "example": req_example,
                }
            },
        },
        "responses": std_responses(summary + " succeeded", res_example),
    }


def get_op(
    tag: str,
    summary: str,
    description: str,
    res_example: Any,
    operation_id: str,
    path_params: Optional[List[Dict[str, str]]] = None,
    query_params: Optional[List[Dict[str, str]]] = None,
    include_404: bool = False,
) -> Dict[str, Any]:
    parameters: List[Dict[str, Any]] = []
    if path_params:
        for p in path_params:
            parameters.append(
                {
                    "name": p["name"],
                    "in": "path",
                    "required": True,
                    "description": p.get("description", f"Resource {p['name']}"),
                    "schema": {"type": "string"},
                    "example": p.get("example", "KORA-DYN-001"),
                }
            )
    if query_params:
        for q in query_params:
            parameters.append(
                {
                    "name": q["name"],
                    "in": "query",
                    "required": False,
                    "description": q.get("description", f"Query filter {q['name']}"),
                    "schema": {"type": "string"},
                    "example": q.get("example", ""),
                }
            )
    op: Dict[str, Any] = {
        "tags": [tag],
        "summary": summary,
        "description": description,
        "operationId": operation_id,
        "responses": std_responses(summary + " succeeded", res_example, include_404=include_404),
    }
    if parameters:
        op["parameters"] = parameters
    return op


def build_openapi_spec(stub_count: int) -> Dict[str, Any]:
    tags = [
        {
            "name": "Collections / Pay-ins",
            "description": "Initialize checkout charges, bank transfers, mobile money, Pay With Bank, EFT, and query charge status.",
        },
        {
            "name": "Card & OTP Scenarios",
            "description": "Stateful finite-state-machine card payment lifecycles with OTP challenge (`00000` invalid vs `12345` valid) and idempotency testing.",
        },
        {
            "name": "Virtual Bank Accounts",
            "description": "Create dedicated virtual bank accounts (VBA), fetch VBA details by reference, list inward transactions, and simulate sandbox credits.",
        },
        {
            "name": "Disbursements & Bulk Payouts",
            "description": "Single and bulk bank/mobile-money payouts, stateful polling (`PAYOUT-SCENARIO-001`), and bulk batch verification.",
        },
        {
            "name": "Refunds",
            "description": "Initiate transaction refunds (coupled with merchant balance deduction) and query refund status by reference.",
        },
        {
            "name": "Balances & Settlements",
            "description": "Retrieve multi-currency merchant wallet balances (`NGN`, `KES`, `GHS`, `USD`), wallet ledger history, and settlements.",
        },
        {
            "name": "Verification & FX Utilities",
            "description": "List Nigerian banks and African Mobile Money Operators, resolve account names, and execute FX conversions.",
        },
        {
            "name": "Identity KYC - Nigeria",
            "description": "Verify Nigerian BVN, NIN, vNIN, Phone Number, Bank Account, Driver's License, Voter's Card (PVC), and International Passport.",
        },
        {
            "name": "Identity KYB - Business",
            "description": "Verify Nigerian Corporate Affairs Commission (CAC) registrations (`RC`, `BN`, `IT`) and Tax Identification Numbers (TIN).",
        },
        {
            "name": "Identity KYC - Pan-Africa",
            "description": "Verify national identities across Kenya (National ID, KRA PIN, Passport), Ghana (Ghana Card, SSNIT, Voter's Card), and South Africa (Smart ID).",
        },
        {
            "name": "Identity Verification Management",
            "description": "Retrieve stored KYC/KYB verification records by reference (`VR-*`), list verification history, verify document authenticity, and complete consent scenarios.",
        },
    ]

    paths: Dict[str, Any] = {
        # ------------------------------------------------------------------
        # 1. Collections / Pay-ins & Card Scenarios
        # ------------------------------------------------------------------
        "/merchant/api/v1/charges/initialize": {
            "post": post_op(
                "Collections / Pay-ins",
                "Initialize Checkout Charge (Stateful)",
                "Records dynamic charge state in `wiremock-state-extension` indexed by `reference` (Priority 5). Use `reference: \"IDEMPOTENT-REF-001\"` to test the `Idempotency-Flow` scenario (Priority 3).",
                {
                    "amount": "25000.50",
                    "currency": "NGN",
                    "reference": "DOCS-TRY-001",
                    "narration": "Order #1001 Payment",
                    "notification_url": "https://webhook.site/kora-test",
                    "redirect_url": "https://merchant.kora.test/callback",
                    "customer": {"name": "Alice Wonderland", "email": "alice@kora.test"},
                },
                {
                    "reference": "DOCS-TRY-001",
                    "checkout_url": "https://test-checkout.korapay.com/pay/DOCS-TRY-001",
                },
                "initializeCharge",
            )
        },
        "/merchant/api/v1/charges/bank-transfer": {
            "post": post_op(
                "Collections / Pay-ins",
                "Charge via Bank Transfer (Stateful)",
                "Creates a dynamic dynamic bank-transfer charge with a Wema Bank virtual account and stores state under `reference`.",
                {
                    "account_name": "Bob Builder Virtual",
                    "amount": 15000,
                    "currency": "NGN",
                    "reference": "KORA-BT-001",
                    "customer": {"name": "Bob Builder", "email": "bob@kora.test"},
                },
                {
                    "currency": "NGN",
                    "amount": "15000",
                    "reference": "KORA-BT-001",
                    "status": "processing",
                    "bank_account": {
                        "account_name": "Bob Builder Virtual",
                        "account_number": "7812345678",
                        "bank_code": "035",
                        "bank_name": "Wema Bank",
                    },
                },
                "chargeBankTransfer",
            )
        },
        "/merchant/api/v1/charges/mobile-money": {
            "post": post_op(
                "Collections / Pay-ins",
                "Charge via Mobile Money (Stateful)",
                "Initiates a Mobile Money charge (`KES`/`GHS`) and records dynamic state under `reference`.",
                {
                    "reference": "KORA-MOMO-001",
                    "amount": 3000,
                    "currency": "KES",
                    "mobile_money": {"number": "254700000000"},
                    "customer": {"name": "Kenya User", "email": "kenya@kora.test"},
                },
                {
                    "currency": "KES",
                    "amount": "3000",
                    "auth_model": "STK_PROMPT",
                    "reference": "KORA-MOMO-001",
                    "status": "processing",
                },
                "chargeMobileMoney",
            )
        },
        "/merchant/api/v1/charges/mobile-money/authorize": {
            "post": post_op(
                "Collections / Pay-ins",
                "Authorize Mobile Money Charge",
                "Authorizes a pending Mobile Money OTP/STK charge and updates state to `success`.",
                {
                    "transaction_reference": "KORA-MOMO-001",
                    "authorization": {"otp": "123456"},
                },
                {
                    "status": "success",
                    "reference": "KORA-MOMO-001",
                    "transaction_reference": "KORA-MOMO-001",
                },
                "authorizeMobileMoney",
            )
        },
        "/merchant/api/v1/charges/mobile-money/resend-otp": {
            "post": post_op(
                "Collections / Pay-ins",
                "Resend Mobile Money OTP / STK Prompt",
                "Resends the OTP or STK prompt for an in-flight Mobile Money transaction.",
                {"transaction_reference": "KORA-MOMO-001"},
                {"reference": "KORA-MOMO-001", "status": "processing"},
                "resendMobileMoneyOtp",
            )
        },
        "/merchant/api/v1/charges/card": {
            "post": post_op(
                "Card & OTP Scenarios",
                "Initiate Card Charge (Scenario: Card-Charge-Lifecycle)",
                "Transitions `Card-Charge-Lifecycle` from `Started` to `Pending_OTP` and returns `transaction_reference: \"CARD-SCENARIO-001\"` requiring OTP authorization.",
                {"charge_data": "encrypted_card_payload_simulation"},
                {
                    "transaction_reference": "CARD-SCENARIO-001",
                    "reference": "CARD-SCENARIO-001",
                    "currency": "NGN",
                    "amount": 12500.0,
                    "status": "processing",
                    "auth_model": "OTP",
                },
                "chargeCard",
            )
        },
        "/merchant/api/v1/charges/card/authorize": {
            "post": post_op(
                "Card & OTP Scenarios",
                "Authorize Card Charge with OTP (12345 = Valid, 00000 = Invalid)",
                "Validates the OTP for `CARD-SCENARIO-001`. Sending `otp: \"00000\"` returns `400 Bad Request` and stays in `Pending_OTP`. Sending `otp: \"12345\"` transitions `Card-Charge-Lifecycle` to `Succeeded` (`200 OK`).",
                {
                    "transaction_reference": "CARD-SCENARIO-001",
                    "authorization": {"otp": "12345"},
                },
                {
                    "transaction_reference": "CARD-SCENARIO-001",
                    "reference": "CARD-SCENARIO-001",
                    "status": "success",
                    "auth_model": "NO_AUTH",
                },
                "authorizeCardCharge",
            )
        },
        "/merchant/api/v1/charges/card/resend-otp": {
            "post": post_op(
                "Card & OTP Scenarios",
                "Resend Card Charge OTP",
                "Resends the one-time password for a pending card charge.",
                {"transaction_reference": "CARD-SCENARIO-001"},
                {"transaction_reference": "CARD-SCENARIO-001", "status": "processing"},
                "resendCardOtp",
            )
        },
        "/merchant/api/v1/charges/pay-with-bank": {
            "post": post_op(
                "Collections / Pay-ins",
                "Initiate Pay With Bank Charge (Stateful)",
                "Initiates a Pay With Bank charge and persists state under `reference`.",
                {
                    "reference": "PWB-DYN-001",
                    "amount": 18000,
                    "currency": "NGN",
                    "bank_code": "058",
                    "customer": {"name": "PWB User", "email": "pwb@kora.test"},
                },
                {
                    "reference": "PWB-DYN-001",
                    "amount": "18000",
                    "currency": "NGN",
                    "status": "processing",
                    "authorization": {"redirect_url": "https://pay.korapay.com/eft/PWB-DYN-001"},
                },
                "chargePayWithBank",
            )
        },
        "/merchant/api/v1/charges/pay-with-bank/authorize": {
            "post": post_op(
                "Collections / Pay-ins",
                "Authorize Pay With Bank Charge",
                "Authorizes a pending Pay With Bank charge.",
                {"transaction_reference": "PWB-DYN-001"},
                {"status": "success", "reference": "PWB-DYN-001"},
                "authorizePayWithBank",
            )
        },
        "/merchant/api/v1/charges/pay-with-bank/banks": {
            "get": get_op(
                "Collections / Pay-ins",
                "List Pay With Bank Supported Banks",
                "Returns all banks supported for Pay With Bank / Instant EFT collections.",
                [
                    {"name": "ABSA Bank", "slug": "absa-bank", "code": "632005", "country": "ZA", "currency": "ZAR"},
                    {"name": "First National Bank (FNB)", "slug": "first-national-bank", "code": "250655", "country": "ZA", "currency": "ZAR"},
                ],
                "listPayWithBankBanks",
            )
        },
        "/merchant/api/v1/charges/eft": {
            "post": post_op(
                "Collections / Pay-ins",
                "Initiate Instant EFT Charge (Stateful)",
                "Initiates a South African Instant EFT charge (`ZAR`) and records state under `reference`.",
                {
                    "reference": "EFT-DYN-001",
                    "amount": 1200,
                    "currency": "ZAR",
                    "customer": {"name": "SA Customer", "email": "zar@kora.test"},
                },
                {
                    "reference": "EFT-DYN-001",
                    "amount": "1200",
                    "currency": "ZAR",
                    "status": "processing",
                },
                "chargeEft",
            )
        },
        "/merchant/api/v1/charges/{reference}": {
            "get": get_op(
                "Collections / Pay-ins",
                "Get Charge by Reference (Stateful Lookup)",
                "Looks up the charge in `wiremock-state-extension` using `state-matcher` (`hasContext: \"{{request.path.reference}}\"`). Returns `200 OK` with the recorded charge details if found, or `404 Not Found` if unknown.",
                {
                    "reference": "DOCS-TRY-001",
                    "currency": "NGN",
                    "amount": "25000.50",
                    "status": "success",
                    "payment_method": "checkout",
                    "customer": {"name": "Alice Wonderland", "email": "alice@kora.test"},
                },
                "getChargeByReference",
                path_params=[{"name": "reference", "example": "DOCS-TRY-001", "description": "Unique charge reference"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/charges": {
            "get": get_op(
                "Collections / Pay-ins",
                "List Charges",
                "Returns a paginated list of pay-in charges.",
                [{"reference": "KORA-DYN-001", "amount": "25000.50", "currency": "NGN", "status": "success"}],
                "listCharges",
            )
        },
        "/merchant/api/v1/pay-ins": {
            "get": get_op(
                "Collections / Pay-ins",
                "List Pay-ins (Alias)",
                "Returns a paginated list of pay-in transactions.",
                [{"reference": "KORA-DYN-001", "amount": "25000.50", "currency": "NGN", "status": "success"}],
                "listPayIns",
            )
        },
        # ------------------------------------------------------------------
        # 2. Virtual Bank Accounts
        # ------------------------------------------------------------------
        "/merchant/api/v1/virtual-bank-account": {
            "post": post_op(
                "Virtual Bank Accounts",
                "Create Virtual Bank Account (Stateful)",
                "Creates a dedicated Virtual Bank Account and records state under `account_reference`.",
                {
                    "account_name": "Acme Merchant VBA",
                    "account_reference": "VBA-REF-001",
                    "permanent": True,
                    "bank_code": "070",
                    "customer": {"name": "Acme Corp", "email": "acme@kora.test"},
                },
                {
                    "account_name": "Acme Merchant VBA",
                    "account_number": "0657789765",
                    "bank_code": "070",
                    "bank_name": "Fidelity Bank",
                    "account_reference": "VBA-REF-001",
                    "account_status": "active",
                },
                "createVirtualBankAccount",
            )
        },
        "/merchant/api/v1/virtual-bank-account/transactions": {
            "get": get_op(
                "Virtual Bank Accounts",
                "List Virtual Bank Account Transactions",
                "Retrieves inward credit transactions for a Virtual Bank Account.",
                {
                    "total_amount_received": 15000.0,
                    "account_number": "0657789765",
                    "currency": "NGN",
                    "transactions": [{"reference": "KPY-VBA-TX-001", "status": "success", "amount": "15000.00"}],
                },
                "listVirtualBankAccountTransactions",
                query_params=[{"name": "account_number", "example": "0657789765", "description": "10-digit NUBAN account number"}],
            )
        },
        "/merchant/api/v1/virtual-bank-account/{account_reference}": {
            "get": get_op(
                "Virtual Bank Accounts",
                "Get Virtual Bank Account by Reference (Stateful Lookup)",
                "Returns the stored Virtual Bank Account for `account_reference` via `state-matcher` or `404 Not Found`.",
                {
                    "account_name": "Acme Merchant VBA",
                    "account_number": "0657789765",
                    "bank_code": "070",
                    "bank_name": "Fidelity Bank",
                    "account_reference": "VBA-REF-001",
                    "account_status": "active",
                },
                "getVirtualBankAccountByReference",
                path_params=[{"name": "account_reference", "example": "VBA-REF-001"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/virtual-bank-account/sandbox/credit": {
            "post": post_op(
                "Virtual Bank Accounts",
                "Credit Sandbox Virtual Bank Account",
                "Simulates an incoming bank transfer credit to a sandbox Virtual Bank Account.",
                {"account_number": "0657789765", "amount": 25000, "currency": "NGN"},
                {"account_number": "0657789765", "amount": "25000", "currency": "NGN", "status": "success"},
                "creditSandboxVirtualBankAccount",
            )
        },
        # ------------------------------------------------------------------
        # 3. Disbursements & Bulk Payouts
        # ------------------------------------------------------------------
        "/merchant/api/v1/transactions/disburse": {
            "post": post_op(
                "Disbursements & Bulk Payouts",
                "Disburse Single Payout (Stateful & Scenario)",
                "Initiates a single payout and records state under `reference`. Use `reference: \"PAYOUT-SCENARIO-001\"` to trigger the `Payout-Lifecycle` polling scenario (`Started` -> `Processing` -> `Completed`).",
                {
                    "reference": "PAYOUT-DYN-001",
                    "destination": {
                        "type": "bank_account",
                        "amount": 50000,
                        "currency": "NGN",
                        "narration": "Contractor Payout",
                        "bank_account": {"bank": "033", "account": "2158634852"},
                        "customer": {"name": "Ebuka Ciroma", "email": "ebuka@kora.test"},
                    },
                },
                {
                    "amount": "50000",
                    "fee": "50.00",
                    "currency": "NGN",
                    "status": "processing",
                    "reference": "PAYOUT-DYN-001",
                },
                "disburseSinglePayout",
            )
        },
        "/merchant/api/v1/transactions/disburse/bulk": {
            "post": post_op(
                "Disbursements & Bulk Payouts",
                "Disburse Bulk Payouts (Stateful)",
                "Queues a batch of payouts and records batch state under `batch_reference`.",
                {
                    "batch_reference": "BATCH-001",
                    "description": "Monthly Payroll",
                    "merchant_bears_cost": True,
                    "currency": "NGN",
                    "payouts": [
                        {
                            "reference": "BULK-ITEM-1",
                            "amount": 50000,
                            "type": "bank_account",
                            "narration": "Salary 1",
                            "bank_account": {"bank_code": "033", "account_number": "2158634852"},
                            "customer": {"name": "Staff One", "email": "staff1@kora.test"},
                        }
                    ],
                },
                {
                    "batch_reference": "BATCH-001",
                    "currency": "NGN",
                    "description": "Monthly Payroll",
                    "status": "processing",
                },
                "disburseBulkPayout",
            )
        },
        "/merchant/api/v1/transactions/bulk/{batch_reference}": {
            "get": get_op(
                "Disbursements & Bulk Payouts",
                "Get Bulk Payout Batch Summary (Stateful Lookup)",
                "Retrieves bulk batch summary from `wiremock-state-extension` for `batch_reference` or returns `404 Not Found`.",
                {
                    "batch_reference": "BATCH-001",
                    "status": "processing",
                    "currency": "NGN",
                    "successful_transactions": 1,
                },
                "getBulkPayoutBatch",
                path_params=[{"name": "batch_reference", "example": "BATCH-001"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/transactions/bulk/{batch_reference}/payout": {
            "get": get_op(
                "Disbursements & Bulk Payouts",
                "List Payout Items in Bulk Batch",
                "Lists individual payout transactions belonging to `batch_reference`.",
                [{"reference": "BULK-ITEM-1", "batch_reference": "BATCH-001", "amount": "50000.00", "status": "success"}],
                "listBulkPayoutItems",
                path_params=[{"name": "batch_reference", "example": "BATCH-001"}],
            )
        },
        "/merchant/api/v1/transactions/{reference}": {
            "get": get_op(
                "Disbursements & Bulk Payouts",
                "Get Payout Transaction by Reference (Stateful & Scenario Polling)",
                "Returns stored payout details for `reference` (`200 OK` or `404 Not Found`). For `PAYOUT-SCENARIO-001`, the first poll returns `status: \"processing\"` and transitions to `Completed`; subsequent polls return `status: \"success\"`.",
                {
                    "reference": "PAYOUT-DYN-001",
                    "amount": "50000",
                    "fee": "50.00",
                    "currency": "NGN",
                    "status": "success",
                },
                "getTransactionByReference",
                path_params=[{"name": "reference", "example": "PAYOUT-DYN-001"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/transactions": {
            "get": get_op(
                "Disbursements & Bulk Payouts",
                "List Payout Transactions",
                "Returns a paginated list of payout transactions.",
                [{"reference": "PAYOUT-DYN-001", "amount": "50000", "currency": "NGN", "status": "success"}],
                "listTransactions",
            )
        },
        "/merchant/api/v1/payouts": {
            "get": get_op(
                "Disbursements & Bulk Payouts",
                "List Payouts (Alias)",
                "Returns a paginated list of payouts.",
                [{"reference": "PAYOUT-DYN-001", "amount": "50000", "currency": "NGN", "status": "success"}],
                "listPayouts",
            )
        },
        # ------------------------------------------------------------------
        # 4. Refunds, Balances & Settlements
        # ------------------------------------------------------------------
        "/merchant/api/v1/refunds/initiate": {
            "post": post_op(
                "Refunds",
                "Initiate Refund (Stateful & Deducts Merchant Balance)",
                "Records refund state under `reference` and transitions `Refund-Balance-Lifecycle` from `Started` (`500000` NGN) to `Refunded` (`450000` NGN).",
                {
                    "reference": "REFUND-SCENARIO-001",
                    "payment_reference": "KPY-ORIG-001",
                    "amount": 50000,
                    "currency": "NGN",
                    "reason": "Order cancelled",
                },
                {
                    "refund_reference": "REFUND-SCENARIO-001",
                    "payment_reference": "KPY-ORIG-001",
                    "amount": "50000",
                    "currency": "NGN",
                    "status": "completed",
                },
                "initiateRefund",
            )
        },
        "/merchant/api/v1/refunds/{reference}": {
            "get": get_op(
                "Refunds",
                "Get Refund by Reference (Stateful Lookup)",
                "Retrieves stored refund state for `reference` via `state-matcher` or returns `404 Not Found`.",
                {
                    "refund_reference": "REFUND-SCENARIO-001",
                    "payment_reference": "KPY-ORIG-001",
                    "amount": "50000",
                    "currency": "NGN",
                    "status": "completed",
                },
                "getRefundByReference",
                path_params=[{"name": "reference", "example": "REFUND-SCENARIO-001"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/refunds": {
            "get": get_op(
                "Refunds",
                "List Refunds",
                "Returns a paginated list of refunds.",
                [{"refund_reference": "REFUND-SCENARIO-001", "amount": "50000", "currency": "NGN", "status": "completed"}],
                "listRefunds",
            )
        },
        "/merchant/api/v1/balances": {
            "get": get_op(
                "Balances & Settlements",
                "Get Merchant Balances (Scenario-Aware)",
                "Returns available and pending balances across `NGN`, `KES`, `GHS`, and `USD`. Returns `500000` NGN in `Started` state and `450000` NGN after `POST /refunds/initiate` transitions `Refund-Balance-Lifecycle` to `Refunded`.",
                {
                    "NGN": {"pending_balance": 25000, "available_balance": 500000},
                    "KES": {"pending_balance": 1200, "available_balance": 150000},
                    "GHS": {"pending_balance": 0, "available_balance": 35000},
                    "USD": {"pending_balance": 500, "available_balance": 12000},
                },
                "getBalances",
            )
        },
        "/merchant/api/v1/balances/history": {
            "get": get_op(
                "Balances & Settlements",
                "Get Merchant Wallet Balance History",
                "Returns paginated ledger credit/debit entries.",
                [
                    {
                        "reference": "KPY-LEDGER-001",
                        "currency": "NGN",
                        "amount": 25000.5,
                        "direction": "credit",
                        "balance_before": 474999.5,
                        "balance_after": 500000.0,
                    }
                ],
                "getBalanceHistory",
            )
        },
        "/merchant/api/v1/settlements": {
            "get": get_op(
                "Balances & Settlements",
                "List Merchant Settlements",
                "Returns a paginated list of merchant settlements.",
                [{"reference": "STL-2025-001", "currency": "NGN", "total_amount": 485000.0, "status": "settled"}],
                "listSettlements",
            )
        },
        "/merchant/api/v1/settlements/{reference}": {
            "get": get_op(
                "Balances & Settlements",
                "Get Settlement by Reference",
                "Fetches details of a single settlement by `reference`.",
                {"reference": "STL-2025-001", "currency": "NGN", "total_amount": 485000, "status": "settled"},
                "getSettlementByReference",
                path_params=[{"name": "reference", "example": "STL-2025-001"}],
            )
        },
        # ------------------------------------------------------------------
        # 5. Verification & FX Utilities
        # ------------------------------------------------------------------
        "/merchant/api/v1/misc/banks": {
            "get": get_op(
                "Verification & FX Utilities",
                "List Supported Banks",
                "Returns supported Nigerian commercial banks (`044`, `058`, `033`, `035`, `057`).",
                [{"name": "United Bank for Africa", "slug": "united-bank-for-africa", "code": "033", "country": "NG"}],
                "listBanks",
            )
        },
        "/merchant/api/v1/misc/banks/resolve": {
            "post": post_op(
                "Verification & FX Utilities",
                "Resolve Bank Account Number",
                "Resolves a bank code and NUBAN account number to the account holder's name (`EBUKA CIROMA OLADEMJI`).",
                {"bank": "033", "account": "2158634852"},
                {
                    "bank_name": "United Bank for Africa",
                    "bank_code": "033",
                    "account_number": "2158634852",
                    "account_name": "EBUKA CIROMA OLADEMJI",
                },
                "resolveBankAccount",
            )
        },
        "/merchant/api/v1/misc/mobile-money/operators": {
            "get": get_op(
                "Verification & FX Utilities",
                "List Mobile Money Operators",
                "Returns supported African Mobile Money Operators (`mtn-gh`, `safaricom-ke`, etc.).",
                [{"name": "MTN Mobile Money Ghana", "slug": "mtn-gh", "code": "mtn-gh", "country": "GH", "currency": "GHS"}],
                "listMobileMoneyOperators",
            )
        },
        "/merchant/api/v1/misc/mobile-money/resolve": {
            "post": post_op(
                "Verification & FX Utilities",
                "Resolve Mobile Money Subscriber",
                "Resolves a mobile money wallet phone number and operator code to `KWAME MENSAH`.",
                {"phoneNumber": "0241234567", "mobileMoneyCode": "mtn-gh"},
                {"account_name": "KWAME MENSAH", "phoneNumber": "0241234567", "mobileMoneyCode": "mtn-gh"},
                "resolveMobileMoneyAccount",
            )
        },
        "/merchant/api/v1/conversions/rates": {
            "get": get_op(
                "Verification & FX Utilities",
                "Get FX Conversion Rate",
                "Retrieves the current exchange rate between `from` and `to` currencies.",
                {"from_currency": "USD", "to_currency": "NGN", "rate": "1550.00"},
                "getConversionRate",
                query_params=[
                    {"name": "from", "example": "USD", "description": "Source currency code"},
                    {"name": "to", "example": "NGN", "description": "Target currency code"},
                ],
            )
        },
        "/merchant/api/v1/conversions": {
            "post": post_op(
                "Verification & FX Utilities",
                "Execute Currency Conversion",
                "Converts funds between two merchant currency balances.",
                {"reference": "CONV-TEST-001", "from_currency": "USD", "to_currency": "NGN", "amount": 100},
                {
                    "reference": "CONV-TEST-001",
                    "from_currency": "USD",
                    "to_currency": "NGN",
                    "amount": "100",
                    "converted_amount": "155000.00",
                    "rate": "1550.00",
                    "status": "success",
                },
                "executeConversion",
            )
        },
        # ------------------------------------------------------------------
        # 6. Identity KYC - Nigeria
        # ------------------------------------------------------------------
        "/merchant/api/v1/identities/ng/bvn": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria Bank Verification Number (BVN)",
                "Verifies an 11-digit Nigerian BVN and stores the verification record under `VR-BVN-{{id}}`. Requires `verification_consent: true` (passing `false` triggers the Priority 4 Consent Validation Guard `400 Bad Request`). Passing `id: \"ID-SCENARIO-001\"` initiates the `Identity-Verification-Lifecycle` scenario.",
                {
                    "id": "11111111111",
                    "verification_consent": True,
                    "first_name": "Trevor",
                    "last_name": "Mandela",
                },
                {
                    "reference": "VR-BVN-11111111111",
                    "id": "11111111111",
                    "id_type": "ng_bvn",
                    "first_name": "Trevor",
                    "last_name": "Mandela",
                    "date_of_birth": "1989-07-08",
                    "status": "verified",
                    "facial_match": {"confidence_score": 96.5, "match": True},
                },
                "verifyNigeriaBvn",
            )
        },
        "/merchant/api/v1/identities/ng/nin": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria National Identification Number (NIN)",
                "Verifies an 11-digit Nigerian NIN and records state under `VR-NIN-{{id}}`.",
                {"id": "22222222222", "verification_consent": True},
                {
                    "reference": "VR-NIN-22222222222",
                    "id": "22222222222",
                    "id_type": "ng_nin",
                    "first_name": "Trevor",
                    "last_name": "Mandela",
                    "status": "verified",
                },
                "verifyNigeriaNin",
            )
        },
        "/merchant/api/v1/identities/ng/vnin": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria Virtual NIN (vNIN)",
                "Verifies a 16-character NIMC Virtual NIN and records state under `VR-VNIN-{{id}}`.",
                {"id": "AA123456789012BB", "verification_consent": True},
                {
                    "reference": "VR-VNIN-AA123456789012BB",
                    "id": "AA123456789012BB",
                    "id_type": "ng_vnin",
                    "status": "verified",
                },
                "verifyNigeriaVnin",
            )
        },
        "/merchant/api/v1/identities/ng/phone": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria Phone Number",
                "Verifies a Nigerian subscriber phone number and records state under `VR-PHN-{{id}}`.",
                {"id": "08031234567", "verification_consent": True},
                {
                    "reference": "VR-PHN-08031234567",
                    "id": "08031234567",
                    "id_type": "ng_phone",
                    "first_name": "Trevor",
                    "last_name": "Mandela",
                    "status": "verified",
                },
                "verifyNigeriaPhone",
            )
        },
        "/merchant/api/v1/identities/ng/bank-account": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria Bank Account Identity (KYC)",
                "Verifies a Nigerian NUBAN bank account + BVN identity linkage and records state under `VR-BA-{{account_number}}`.",
                {"account_number": "2158634852", "bank_code": "033", "verification_consent": True},
                {
                    "reference": "VR-BA-2158634852",
                    "account_number": "2158634852",
                    "bank_code": "033",
                    "account_name": "EBUKA CIROMA OLADEMJI",
                    "bvn": "22222222222",
                    "status": "verified",
                },
                "verifyNigeriaBankAccountKyc",
            )
        },
        "/merchant/api/v1/identities/ng/drivers-license": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria FRSC Driver's License",
                "Verifies a Nigerian Driver's License and records state under `VR-DL-{{id}}`.",
                {"id": "FKJ12345AA01", "verification_consent": True},
                {
                    "reference": "VR-DL-FKJ12345AA01",
                    "id": "FKJ12345AA01",
                    "id_type": "ng_drivers_license",
                    "status": "verified",
                },
                "verifyNigeriaDriversLicense",
            )
        },
        "/merchant/api/v1/identities/ng/voters-card": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria INEC Voter's Card (PVC)",
                "Verifies a Nigerian Permanent Voter's Card and records state under `VR-VC-{{id}}`.",
                {"id": "90F5B1234567890", "verification_consent": True},
                {
                    "reference": "VR-VC-90F5B1234567890",
                    "id": "90F5B1234567890",
                    "id_type": "ng_voters_card",
                    "status": "verified",
                },
                "verifyNigeriaVotersCard",
            )
        },
        "/merchant/api/v1/identities/ng/passport": {
            "post": post_op(
                "Identity KYC - Nigeria",
                "Verify Nigeria International Passport",
                "Verifies a Nigerian International Passport and records state under `VR-PP-{{id}}`.",
                {"id": "A12345678", "verification_consent": True, "last_name": "Mandela"},
                {
                    "reference": "VR-PP-A12345678",
                    "id": "A12345678",
                    "id_type": "ng_passport",
                    "status": "verified",
                },
                "verifyNigeriaPassport",
            )
        },
        # ------------------------------------------------------------------
        # 7. Identity KYB - Business
        # ------------------------------------------------------------------
        "/merchant/api/v1/identities/ng/cac": {
            "post": post_op(
                "Identity KYB - Business",
                "Verify Nigeria CAC Business Registration (KYB)",
                "Verifies a Nigerian Corporate Affairs Commission registration (`RC`, `BN`, `IT`) and records state under `VR-CAC-{{id}}`.",
                {"id": "1492819", "registration_type": "RC", "verification_consent": True},
                {
                    "reference": "VR-CAC-1492819",
                    "id": "1492819",
                    "rc_number": "1492819",
                    "registration_type": "RC",
                    "company_name": "KORA PAYMENTS LIMITED",
                    "company_status": "ACTIVE",
                    "status": "verified",
                },
                "verifyNigeriaCac",
            )
        },
        "/merchant/api/v1/identities/ng/tin": {
            "post": post_op(
                "Identity KYB - Business",
                "Verify Nigeria Corporate Tax Identification Number (TIN)",
                "Verifies a Nigerian FIRS/JTB Tax Identification Number and records state under `VR-TIN-{{id}}`.",
                {"id": "12345678-0001", "verification_consent": True},
                {
                    "reference": "VR-TIN-12345678-0001",
                    "id": "12345678-0001",
                    "tin": "12345678-0001",
                    "company_name": "KORA PAYMENTS LIMITED",
                    "tax_office": "MSTO LEKKI",
                    "status": "verified",
                },
                "verifyNigeriaTin",
            )
        },
        # ------------------------------------------------------------------
        # 8. Identity KYC - Pan-Africa (Kenya, Ghana, South Africa)
        # ------------------------------------------------------------------
        "/merchant/api/v1/identities/ke/national-id": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Kenya National ID",
                "Verifies a Kenyan National ID and records state under `VR-KE-ID-{{id}}`.",
                {"id": "12345678", "verification_consent": True},
                {
                    "reference": "VR-KE-ID-12345678",
                    "id": "12345678",
                    "country": "KE",
                    "first_name": "Jomo",
                    "last_name": "Kenyatta",
                    "status": "verified",
                },
                "verifyKenyaNationalId",
            )
        },
        "/merchant/api/v1/identities/ke/kra-pin": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Kenya KRA Tax PIN",
                "Verifies a Kenyan Revenue Authority PIN and records state under `VR-KE-KRA-{{id}}`.",
                {"id": "A001234567Z", "verification_consent": True},
                {
                    "reference": "VR-KE-KRA-A001234567Z",
                    "id": "A001234567Z",
                    "country": "KE",
                    "taxpayer_name": "JOMO KENYATTA",
                    "status": "verified",
                },
                "verifyKenyaKraPin",
            )
        },
        "/merchant/api/v1/identities/ke/passport": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Kenya Passport",
                "Verifies a Kenyan International Passport and records state under `VR-KE-PP-{{id}}`.",
                {"id": "AK123456", "verification_consent": True},
                {
                    "reference": "VR-KE-PP-AK123456",
                    "id": "AK123456",
                    "country": "KE",
                    "status": "verified",
                },
                "verifyKenyaPassport",
            )
        },
        "/merchant/api/v1/identities/gh/ghana-card": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Ghana Card (National ID)",
                "Verifies a Ghana Card (`GHA-XXXXXXXXX-X`) and records state under `VR-GH-CARD-{{id}}`.",
                {"id": "GHA-123456789-0", "verification_consent": True},
                {
                    "reference": "VR-GH-CARD-GHA-123456789-0",
                    "id": "GHA-123456789-0",
                    "country": "GH",
                    "first_name": "Kwame",
                    "last_name": "Mensah",
                    "status": "verified",
                },
                "verifyGhanaCard",
            )
        },
        "/merchant/api/v1/identities/gh/ssnit": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Ghana SSNIT Number",
                "Verifies a Ghana Social Security and National Insurance Trust number and records state under `VR-GH-ID-{{id}}`.",
                {"id": "C001234567890", "verification_consent": True},
                {
                    "reference": "VR-GH-ID-C001234567890",
                    "id": "C001234567890",
                    "country": "GH",
                    "status": "verified",
                },
                "verifyGhanaSsnit",
            )
        },
        "/merchant/api/v1/identities/gh/voters-card": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify Ghana Voter's Card",
                "Verifies a Ghana Electoral Commission Voter ID and records state under `VR-GH-ID-{{id}}`.",
                {"id": "2345678901", "verification_consent": True},
                {
                    "reference": "VR-GH-ID-2345678901",
                    "id": "2345678901",
                    "country": "GH",
                    "status": "verified",
                },
                "verifyGhanaVotersCard",
            )
        },
        "/merchant/api/v1/identities/za/national-id": {
            "post": post_op(
                "Identity KYC - Pan-Africa",
                "Verify South Africa Smart National ID",
                "Verifies a 13-digit South African Smart National ID and records state under `VR-ZA-{{id}}`.",
                {"id": "8907085000081", "verification_consent": True},
                {
                    "reference": "VR-ZA-8907085000081",
                    "id": "8907085000081",
                    "country": "ZA",
                    "first_name": "Sipho",
                    "last_name": "Nkosi",
                    "citizenship": "ZA Citizen",
                    "status": "verified",
                },
                "verifySouthAfricaNationalId",
            )
        },
        # ------------------------------------------------------------------
        # 9. Identity Verification Management
        # ------------------------------------------------------------------
        "/merchant/api/v1/identities/verifications/{reference}": {
            "get": get_op(
                "Identity Verification Management",
                "Get Verification Record by Reference (Stateful Lookup)",
                "Retrieves any previously verified KYC/KYB record (`VR-BVN-*`, `VR-CAC-*`, `VR-SCENARIO-001`, etc.) from `wiremock-state-extension` via `state-matcher` (`200 OK`) or returns `404 Not Found` if unknown.",
                {
                    "reference": "VR-BVN-11111111111",
                    "id": "11111111111",
                    "id_type": "ng_bvn",
                    "first_name": "Trevor",
                    "last_name": "Mandela",
                    "status": "verified",
                },
                "getIdentityVerificationByReference",
                path_params=[{"name": "reference", "example": "VR-BVN-11111111111"}],
                include_404=True,
            )
        },
        "/merchant/api/v1/identities/verifications": {
            "get": get_op(
                "Identity Verification Management",
                "List Identity Verification History",
                "Returns a paginated list of historical identity verification records.",
                [{"reference": "VR-BVN-11111111111", "id": "11111111111", "id_type": "ng_bvn", "status": "verified"}],
                "listIdentityVerifications",
            ),
            "post": post_op(
                "Identity Verification Management",
                "Filter Identity Verification History",
                "Queries historical identity verification records with filter criteria.",
                {"page": 1, "per_page": 20},
                [{"reference": "VR-BVN-11111111111", "id": "11111111111", "id_type": "ng_bvn", "status": "verified"}],
                "filterIdentityVerifications",
            ),
        },
        "/merchant/api/v1/identities/verifications/documents": {
            "post": post_op(
                "Identity Verification Management",
                "Verify Identity Document Authenticity",
                "Performs optical and biometric authenticity verification on an uploaded identity document.",
                {"document_type": "passport", "country": "NG", "document_image": "base64_encoded_image_data"},
                {"reference": "VR-DOC-001", "status": "verified", "authenticity_score": 98.2},
                "verifyIdentityDocument",
            )
        },
        "/merchant/api/v1/identities/verifications/consent": {
            "post": post_op(
                "Identity Verification Management",
                "Confirm Customer Verification Consent (Scenario: Identity-Verification-Lifecycle)",
                "Transitions `Identity-Verification-Lifecycle` from `Pending_Consent` to `Verified` for `reference: \"VR-SCENARIO-001\"`.",
                {"reference": "VR-SCENARIO-001", "otp": "123456"},
                {"reference": "VR-SCENARIO-001", "id": "ID-SCENARIO-001", "status": "verified"},
                "confirmIdentityConsent",
            )
        },
    }

    return {
        "openapi": "3.0.3",
        "info": {
            "title": "Kora (Korapay) Complete Stateful Mock API — Payments & Identity (KYC/KYB)",
            "version": "1.0.0",
            "description": (
                "Interactive OpenAPI 3.0.3 specification for the containerized **Kora (formerly Korapay) Stateful WireMock Server**.\n\n"
                "### Key Capabilities\n"
                "- **Dynamic Stateful Persistence (`wiremock-state-extension`)**: Every `POST` creation endpoint records state indexed by `reference` (or `account_reference` / `batch_reference` / `VR-*`), which can be immediately queried back via the corresponding `GET` endpoint.\n"
                "- **Finite-State-Machine Scenarios**: Supports `Card-Charge-Lifecycle` (`CARD-SCENARIO-001`), `Payout-Lifecycle` (`PAYOUT-SCENARIO-001`), `Refund-Balance-Lifecycle` (`REFUND-SCENARIO-001`), `Idempotency-Flow` (`IDEMPOTENT-REF-001`), and `Identity-Verification-Lifecycle` (`ID-SCENARIO-001`).\n"
                f"- **Introspected WireMock Stubs**: Generated from `{stub_count}` active WireMock stub mappings.\n\n"
                "### Pre-Configured Authentication\n"
                "Use Bearer token `sk_test_kora_stateful_mock_2025` (pre-authorized automatically in `/docs`)."
            ),
            "contact": {
                "name": "Kora Developer Documentation",
                "url": "https://developers.korapay.com/docs/getting-started",
            },
        },
        "servers": [
            {
                "url": "http://localhost:8080",
                "description": "Local Kora Stateful WireMock Server (Docker / Port 8080)",
            }
        ],
        "security": [{"BearerAuth": []}],
        "tags": tags,
        "paths": paths,
        "components": {
            "securitySchemes": {
                "BearerAuth": {
                    "type": "http",
                    "scheme": "bearer",
                    "bearerFormat": "Kora API Key (sk_test_* / pk_test_* / sk_live_* / pk_live_*)",
                    "description": "Enter a valid Kora secret or public key, e.g. `sk_test_kora_stateful_mock_2025`.",
                }
            },
            "schemas": {
                "KoraStandardResponse": {
                    "type": "object",
                    "required": ["status", "message", "data"],
                    "properties": {
                        "status": {"type": "boolean", "example": True},
                        "message": {"type": "string", "example": "Operation completed successfully"},
                        "data": {"type": "object", "nullable": True},
                    },
                },
                "KoraErrorResponse": {
                    "type": "object",
                    "required": ["status", "message", "data"],
                    "properties": {
                        "status": {"type": "boolean", "example": False},
                        "message": {"type": "string", "example": "Error message describing failure"},
                        "data": {"type": "object", "nullable": True, "example": None},
                    },
                },
            },
            "responses": {
                "UnauthorizedError": {
                    "description": "Missing or malformed Bearer API key (`sk_test_*` / `pk_test_*`).",
                    "content": {
                        "application/json": {
                            "schema": {"$ref": "#/components/schemas/KoraErrorResponse"},
                            "example": {
                                "status": False,
                                "message": "Unauthorized. Bearer token is missing.",
                                "data": None,
                            },
                        }
                    },
                },
                "BadRequestError": {
                    "description": "Validation error, duplicate idempotent reference, invalid OTP, or missing customer consent.",
                    "content": {
                        "application/json": {
                            "schema": {"$ref": "#/components/schemas/KoraErrorResponse"},
                            "example": {
                                "status": False,
                                "message": "Invalid request parameters or missing customer consent.",
                                "data": None,
                            },
                        }
                    },
                },
                "NotFoundError": {
                    "description": "Requested resource reference was not found in WireMock state.",
                    "content": {
                        "application/json": {
                            "schema": {"$ref": "#/components/schemas/KoraErrorResponse"},
                            "example": {
                                "status": False,
                                "message": "Resource with the specified reference was not found.",
                                "data": None,
                            },
                        }
                    },
                },
            },
        },
    }


def main() -> int:
    repo_root = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
    mappings_dir = os.path.join(repo_root, "wiremock", "mappings")
    files_dir = os.path.join(repo_root, "wiremock", "__files")
    os.makedirs(files_dir, exist_ok=True)

    stub_count = introspect_mappings(mappings_dir)
    spec = build_openapi_spec(stub_count)

    json_path = os.path.join(files_dir, "openapi.json")
    yaml_path = os.path.join(files_dir, "openapi.yaml")

    with open(json_path, "w", encoding="utf-8") as f:
        json.dump(spec, f, indent=2, ensure_ascii=False)
        f.write("\n")

    with open(yaml_path, "w", encoding="utf-8") as f:
        f.write(to_yaml(spec))
        f.write("\n")

    print(
        f"[INFO] Generated OpenAPI 3.0.3 spec ({len(spec['paths'])} paths, {len(spec['tags'])} tags, "
        f"{stub_count} WireMock stubs introspected) -> {json_path} & {yaml_path}"
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
