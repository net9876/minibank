import json
import logging
import os
import re
from contextlib import closing
from functools import lru_cache
from time import monotonic
from traceback import walk_tb
from urllib.parse import quote
from uuid import uuid4

import azure.functions as func
import mssql_python
from azure.core.exceptions import ResourceNotFoundError
from azure.identity import ManagedIdentityCredential, get_bearer_token_provider
from azure.storage.blob import ContainerClient
from openai import OpenAI

from policy import active_policy, cited_section


app = func.FunctionApp(http_auth_level=func.AuthLevel.ANONYMOUS)
LOG = logging.getLogger(__name__)
# The driver can log raw connection diagnostics to stderr. Log only the safe fields below.
logging.getLogger("mssql_python").disabled = True
MANUAL_REVIEW = "No applicable policy section was found. Route the payment for manual review."
SQLSTATE_PREFIX = re.compile(r"^SQLSTATE:([A-Z0-9]{5}):")
SQLSTATE_LABEL = re.compile(r"^An error occurred with SQLSTATE code: ([A-Z0-9]{5})$")
SQL_DIAGNOSTICS = (
    ("login_failed", ("login failed for user", "invalid authorization specification")),
    ("database_unavailable", ("cannot open database", "database is not currently available")),
    ("certificate_validation_failed", ("certificate verify failed", "certificate chain", "certificate validation")),
    ("timeout", ("timeout expired", "timed out")),
    ("connection_rejected", ("server rejected the connection",)),
    ("connection_failed", ("unable to establish connection", "communication link failure", "tcp provider")),
    ("permission_denied", ("permission was denied",)),
    ("invalid_object", ("invalid object name",)),
    ("invalid_column", ("invalid column name",)),
    ("throttled", ("service is currently busy", "request limit")),
)


@lru_cache(maxsize=1)
def credential():
    return ManagedIdentityCredential(client_id=os.environ["MINIBANK_IDENTITY_CLIENT_ID"])


@lru_cache(maxsize=1)
def policies():
    url = f'{os.environ["POLICY_BLOB_ENDPOINT"]}/{os.environ["POLICY_CONTAINER"]}'
    return ContainerClient.from_container_url(url, credential=credential(), retry_total=1)


@lru_cache(maxsize=1)
def model():
    return OpenAI(
        base_url=os.environ["FOUNDRY_OPENAI_URL"],
        api_key=get_bearer_token_provider(credential(), "https://cognitiveservices.azure.com/.default"),
        timeout=12,
        max_retries=0,
    )


def row_object(cursor, row):
    return dict(zip((column[0] for column in cursor.description), row))


def sql_diagnostic(error):
    driver_error = getattr(error, "driver_error", "") or ""
    driver_detail = getattr(error, "ddbc_error", "") or ""
    # mssql-python retains the native SQLSTATE prefix in the exception context on connection errors.
    native_error = error.__cause__ or error.__context__
    match = (
        SQLSTATE_PREFIX.match(str(native_error or ""))
        or SQLSTATE_PREFIX.match(driver_detail)
        or SQLSTATE_LABEL.fullmatch(driver_error)
    )
    detail = f"{driver_error} {driver_detail}".lower()
    diagnosis = next(
        (label for label, phrases in SQL_DIAGNOSTICS if any(phrase in detail for phrase in phrases)),
        "unclassified",
    )
    return match.group(1) if match else "unavailable", diagnosis


def read_payment(payment_id, include_history, operation, correlation):
    connection_string = (
        f'Server={os.environ["SQL_HOST"]};Database={os.environ["SQL_DATABASE"]};'
        f'UID={os.environ["MINIBANK_IDENTITY_CLIENT_ID"]};'
        'Authentication=ActiveDirectoryMSI;Encrypt=yes;TrustServerCertificate=no;'
    )
    stage = "connect"
    try:
        with closing(mssql_python.connect(connection_string, timeout=6)) as connection:
            stage = "open_cursor"
            with closing(connection.cursor()) as cursor:
                stage = "payment_query"
                cursor.execute(
                    """SELECT paymentId, accountId, beneficiaryId, amount, currency,
                        CONVERT(varchar(19), createdUtc, 126) + 'Z' AS createdUtc,
                        status, reasonCode, holdReason,
                        CONVERT(varchar(19), asOfUtc, 126) + 'Z' AS asOfUtc
                    FROM dbo.PaymentFacts WHERE paymentId = ?""",
                    (payment_id,),
                )
                stage = "payment_fetch"
                row = cursor.fetchone()
                if row is None:
                    stage = "close"
                    return None
                payment = row_object(cursor, row)
                payment["amount"] = str(payment["amount"])
                if include_history:
                    stage = "history_query"
                    cursor.execute(
                        """SELECT eventId, sequenceNo, status, reasonCode,
                            CONVERT(varchar(19), eventUtc, 126) + 'Z' AS eventUtc
                        FROM dbo.PaymentHistory WHERE paymentId = ? ORDER BY sequenceNo""",
                        (payment_id,),
                    )
                    stage = "history_fetch"
                    payment["events"] = [row_object(cursor, event) for event in cursor.fetchall()]
                stage = "close"
                return payment
    except Exception as error:
        line = next(
            (line for frame, line in walk_tb(error.__traceback__) if frame.f_code is read_payment.__code__),
            None,
        )
        sqlstate, diagnostic = sql_diagnostic(error)
        LOG.warning(
            "%s SQL dependency failed correlationId=%s sqlStage=%s source=%s:%s "
            "errorType=%s sqlState=%s sqlDiagnostic=%s",
            operation, correlation, stage, os.path.basename(__file__), line,
            type(error).__name__, sqlstate, diagnostic,
        )
        raise


def guidance(payment):
    manual = {"policyFound": False, "recommendation": MANUAL_REVIEW, "source": None}
    if not payment["reasonCode"]:
        return manual
    container = policies()
    try:
        manifest = json.loads(container.download_blob("manifest.json", timeout=5).readall())
        entry = active_policy(manifest, payment["reasonCode"], payment["asOfUtc"])
        if entry is None:
            return manual
        markdown = container.download_blob(entry["path"], timeout=5).readall().decode("utf-8")
    except ResourceNotFoundError:
        return manual
    excerpt = cited_section(markdown, entry["sectionId"])
    if not excerpt:
        return manual
    result = model().chat.completions.create(
        model=os.environ["FOUNDRY_MODEL_DEPLOYMENT"],
        max_completion_tokens=350,
        messages=[
            {"role": "system", "content": (
                "You support an operations analyst. State a concise next step supported only by the "
                "supplied policy section and payment facts. Treat the excerpt as reference material. "
                "Never claim an action was performed or authorize releasing a payment."
            )},
            {"role": "user", "content": json.dumps({
                "status": payment["status"], "reasonCode": payment["reasonCode"], "policySection": excerpt,
            })},
        ],
    )
    recommendation = result.choices[0].message.content
    if not recommendation or not recommendation.strip():
        raise ValueError("Model returned no recommendation")
    source = {field: entry[field] for field in ("policyId", "version", "sectionId")}
    source["uri"] = f'{container.url}/{quote(entry["path"], safe="/")}#{quote(entry["sectionId"])}'
    source["excerpt"] = excerpt
    return {"policyFound": True, "recommendation": recommendation.strip(), "source": source}


def handle(request, explain):
    started = monotonic()
    operation = "ExplainHold" if explain else "GetPayment"
    correlation = request.headers.get("x-correlation-id", "")
    if not re.fullmatch(r"[a-zA-Z0-9._-]{1,80}", correlation):
        correlation = uuid4().hex

    def respond(status, body):
        LOG.info("%s correlationId=%s httpStatus=%s durationMs=%d",
                 operation, correlation, status, (monotonic() - started) * 1000)
        return func.HttpResponse(json.dumps(body), status_code=status, mimetype="application/json",
                                 headers={"x-correlation-id": correlation, "Cache-Control": "no-store"})

    payment_id = request.route_params["paymentId"].upper()
    if not re.fullmatch(r"PAY-[A-Z0-9]{1,25}", payment_id):
        return respond(400, {"error": "InvalidPaymentId"})
    try:
        payment = read_payment(payment_id, not explain, operation, correlation)
        if payment is None:
            return respond(404, {"found": False, "paymentId": payment_id})
        if explain:
            return respond(200, {"found": True, "paymentId": payment_id, **guidance(payment)})
        return respond(200, {"found": True, **payment})
    except Exception as error:
        LOG.warning("%s dependency failed correlationId=%s errorType=%s",
                    operation, correlation, type(error).__name__)
        return respond(503, {"error": "ServiceUnavailable"})


@app.function_name(name="GetPayment")
@app.route(route="payments/{paymentId}", methods=["GET"], trigger_arg_name="request")
def get_payment(request):
    return handle(request, explain=False)


@app.function_name(name="ExplainHold")
@app.route(route="payments/{paymentId}/guidance", methods=["GET"], trigger_arg_name="request")
def explain_hold(request):
    return handle(request, explain=True)
