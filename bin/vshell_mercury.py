"""Mercury banking: balances, recent activity and receipt attachments.

Loaded by `vshell mercury`. It lives beside vshell-helper rather than inside
it for the reason the ratchet exists: the helper is already fifteen thousand
lines, and a self-contained subsystem that talks to one API is a seam, not a
paragraph. vshell_devtools.py and vshell_apps.py are the same shape.

THE API KEY NEVER TOUCHES argv, and never appears in a payload. It is read
from a 0600 file under the state directory or from MERCURY_API_TOKEN, and it
reaches exactly one place: the Authorization header in _mercury_request. The
only key-adjacent thing this module prints is `keySource`, a label reading
"stored", "env" or "none".
"""

from __future__ import annotations

import contextlib
import datetime as _dt
import json
import mimetypes
import os
import sys
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


class MercuryRuntime:
    """What this module needs from the host helper, passed in rather than
    imported: where local state lives, and how to write a usage line."""

    def __init__(self, state_dir: Callable[[], Path], eprint: Callable[[str], None]) -> None:
        self.state_dir = state_dir
        self.eprint = eprint


_RUNTIME: Optional[MercuryRuntime] = None


def configure(runtime: MercuryRuntime) -> None:
    global _RUNTIME
    _RUNTIME = runtime


def state_dir() -> Path:
    if _RUNTIME is None:
        raise RuntimeError("vshell_mercury.configure() was never called")
    return _RUNTIME.state_dir()


def eprint(message: str) -> None:
    if _RUNTIME is None:
        raise RuntimeError("vshell_mercury.configure() was never called")
    _RUNTIME.eprint(message)


MERCURY_API_DEFAULT_BASE = "https://api.mercury.com/api/v1"
# Mercury rejects a larger attachment; the widget cannot stat a file, so this
# is the only place the limit is enforced before the POST.
MERCURY_ATTACHMENT_MAX_BYTES = 32 * 1024 * 1024
# What `upload --type` accepts. The receipt-duplicate gate keys off "receipt",
# so this list and that check move together.
MERCURY_ATTACHMENT_TYPES = ("receipt", "other")
# Every status the widget can render a row for. `blocked` belongs here for the
# same reason the others do: a transaction the bank stopped is one the user
# most wants to see, and leaving it out of the query hid it entirely.
MERCURY_TRANSACTION_STATUSES = ("pending", "sent", "failed", "cancelled", "reversed", "blocked")


def _mercury_token_path() -> Path:
    """Where a key typed into the widget's settings is kept.

    Deliberately NOT the plugin settings file: that lives under
    ~/.config/vshell, which operators routinely symlink into a dotfiles repo,
    and a key written there is one `git add` away from a public remote. This
    path is machine-local state, is never read by the settings serialiser, and
    is written 0600.
    """
    return state_dir() / "mercury-token"


def _mercury_stored_token() -> str:
    try:
        return _mercury_token_path().read_text(encoding="utf-8").strip()
    except OSError:
        return ""


def _mercury_env_token() -> str:
    return os.environ.get("MERCURY_API_TOKEN", "").strip()


def _mercury_resolve_token() -> str:
    """The key to authenticate with, or "" when there is none.

    A key typed into settings wins, because that is the one the user can see
    and change from the shell. MERCURY_API_TOKEN in the environment is the
    fallback for a key provisioned outside VGS (a secret manager writing
    ~/.config/environment.d), which the user may never open settings for.
    """
    return _mercury_stored_token() or _mercury_env_token()


def _mercury_key_source() -> str:
    """Which of the two the key came from, as a label for the settings UI.

    Deliberately NOT returned alongside the key. When the two travelled
    together as a tuple, CodeQL could not tell the label from the secret it
    was read next to, and reported every reply that carries the label as
    clear-text logging of the key. Here the return is one of three literals
    and the key is not in scope, which is true of the code and now visible to
    a reader and a checker alike.
    """
    if _mercury_stored_token():
        return "stored"
    if _mercury_env_token():
        return "env"
    return "none"


def _mercury_request(base: str, token: str, method: str, path: str,
                     raw_body: Optional[bytes] = None,
                     content_type: Optional[str] = None) -> Tuple[int, bytes]:
    """One Mercury API call over IPv4. Returns (status, body); never raises.

    IPv4 is forced because Mercury whitelists a token by source address. On a
    dual-stack machine the default resolution order picks IPv6, and every call
    then fails 401 `ipNotWhitelisted` with a token that is perfectly valid --
    a failure that reads as "wrong key" and is not.

    The getaddrinfo override lives only for the duration of this call. `family`
    is bound as the explicit third positional parameter of the documented
    signature, because urllib passes it positionally; accepting it only as a
    keyword would raise TypeError instead of resolving the host.

    Every transport failure becomes a synthetic status 0 whose body is the
    reason, so callers always emit JSON rather than a traceback.
    """
    import socket as _socket
    from urllib.error import HTTPError, URLError

    headers = {"Authorization": "Bearer " + token, "User-Agent": "vshell-mercury",
               "Accept": "application/json"}
    req = urllib.request.Request(base + path, data=raw_body, method=method, headers=headers)
    if content_type:
        req.add_header("Content-Type", content_type)
    # An HTTP proxy would defeat the IPv4 pin and send the token somewhere the
    # whitelist does not cover, so this opener ignores the proxy environment.
    opener = urllib.request.build_opener(urllib.request.ProxyHandler({}))
    original_getaddrinfo = _socket.getaddrinfo

    def ipv4_getaddrinfo(host, port, family, *args, **kwargs):
        return original_getaddrinfo(host, port, _socket.AF_INET, *args, **kwargs)

    _socket.getaddrinfo = ipv4_getaddrinfo
    try:
        with opener.open(req, timeout=20.0) as resp:
            return resp.status, resp.read()
    except HTTPError as exc:
        return exc.code, exc.read()
    except URLError as exc:
        return 0, str(getattr(exc, "reason", exc)).encode("utf-8", "replace")
    except (TimeoutError, OSError) as exc:
        # A read timeout surfaces as a bare TimeoutError, not inside URLError.
        return 0, str(exc).encode("utf-8", "replace")
    finally:
        _socket.getaddrinfo = original_getaddrinfo


def _mercury_json(body: bytes) -> Any:
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None


def _mercury_error_text(body: bytes, status: int) -> str:
    """The most specific sentence available for a failed call.

    Mercury nests the real payload differently per status: a 404 arrives with
    the whole error re-encoded as a JSON string under `detail`, so that layer
    is unwrapped before the message is looked for.
    """
    data = _mercury_json(body)
    if isinstance(data, dict):
        inner = data.get("detail")
        if isinstance(inner, str):
            parsed_inner = _mercury_json(inner.encode("utf-8"))
            if isinstance(parsed_inner, dict):
                data = parsed_inner
        errors = data.get("errors")
        if isinstance(errors, list) and errors:
            errors = errors[0]
        if isinstance(errors, dict):
            message = str(errors.get("message") or errors.get("detail") or "").strip()
            code = errors.get("errorCode")
            if not message:
                # A 404 uses a third shape entirely: {"errors": {"notFound":
                # ["..."]}}, keyed by the code with the sentence in a list.
                for key, value in errors.items():
                    if isinstance(value, list) and value and isinstance(value[0], str):
                        message = value[0].strip()
                        code = code or key
                        break
            if message and code:
                return f"{message} ({code})"
            if message:
                return message
    if body:
        return body.decode("utf-8", "replace")[:300]
    return f"HTTP {status}"


def _mercury_reason(refused: str, body: bytes, status: int) -> str:
    """The sentence for a failed call, told apart from a call that never landed.

    Status 0 is this helper's synthetic "no HTTP response at all": DNS,
    refusal, timeout. Reporting that as `refused` would send the user off to
    re-enter a key that was never the problem.
    """
    if status == 0:
        return "could not reach Mercury"
    return refused


def _mercury_has_receipt(attachments: Any) -> bool:
    """Whether a receipt is attached.

    Read from the attachments list, never from `hasGeneratedReceipt`: that flag
    is false on live transactions that do carry a receipt attachment, so
    trusting it offers an upload for a transaction already covered -- and there
    is no endpoint to remove the duplicate afterwards.
    """
    if not isinstance(attachments, list):
        return False
    for item in attachments:
        if not isinstance(item, dict):
            continue
        kind = str(item.get("type") or item.get("attachmentType") or "").lower()
        if kind == "receipt":
            return True
    return False


def _mercury_norm_attachment(att: Dict[str, Any]) -> Dict[str, Any]:
    return {"type": att.get("attachmentType") or att.get("type") or "other",
            "fileName": att.get("fileName") or "",
            "url": att.get("url") or ""}


def _mercury_norm_transaction(tx: Dict[str, Any]) -> Dict[str, Any]:
    attachments = tx.get("attachments") or []
    counterparty = (tx.get("counterpartyName") or tx.get("counterpartyNickname")
                    or tx.get("bankDescription") or "")
    return {"id": tx.get("id") or "",
            "accountId": tx.get("accountId") or "",
            "amount": _mercury_float(tx.get("amount")),
            "status": tx.get("status") or "",
            "createdAt": tx.get("createdAt") or "",
            "counterparty": str(counterparty).strip(),
            "kind": tx.get("kind") or "",
            "hasReceipt": _mercury_has_receipt(attachments),
            "attachments": [_mercury_norm_attachment(a) for a in attachments if isinstance(a, dict)],
            "dashboardLink": tx.get("dashboardLink") or ""}


def _mercury_norm_account(account: Dict[str, Any]) -> Dict[str, Any]:
    # The FULL account and routing numbers travel in this payload, because the
    # widget offers to reveal and copy them. They live only in the shell's
    # memory: nothing on the QML side writes a snapshot to disk, and the
    # settings serialiser never sees one. `kind` is what says checking from
    # savings; `type` is "mercury" on every account and cannot pick an icon.
    return {"id": account.get("id") or "",
            "name": account.get("name") or account.get("nickname") or "",
            "type": account.get("type") or "",
            "kind": account.get("kind") or "",
            "status": account.get("status") or "",
            "accountNumber": str(account.get("accountNumber") or ""),
            "routingNumber": str(account.get("routingNumber") or ""),
            "last4": str(account.get("accountNumber") or "")[-4:],
            "dashboardLink": account.get("dashboardLink") or "",
            "currentBalance": _mercury_float(account.get("currentBalance")),
            "availableBalance": _mercury_float(account.get("availableBalance"))}


def _mercury_float(value: Any) -> float:
    """A number the widget can sum.

    A field that is absent, null or unparseable becomes 0.0 rather than
    aborting the snapshot: one odd account must not blank the whole bar, and
    the popout still shows that account's own row.
    """
    try:
        return float(value or 0)
    except (TypeError, ValueError):
        return 0.0


def _mercury_org_name(body: bytes) -> str:
    data = _mercury_json(body)
    inner = data.get("organization") if isinstance(data, dict) else None
    if not isinstance(inner, dict):
        return ""
    name = str(inner.get("legalBusinessName") or "").strip()
    if name:
        return name
    dbas = inner.get("dbas")
    if isinstance(dbas, list) and dbas and isinstance(dbas[0], dict):
        return str(dbas[0].get("dbaName") or "").strip()
    return ""


def _mercury_uploaded_attachments(body: bytes) -> List[Dict[str, Any]]:
    data = _mercury_json(body)
    attachments = data.get("attachments") if isinstance(data, dict) else None
    if not isinstance(attachments, list):
        return []
    return [_mercury_norm_attachment(a) for a in attachments if isinstance(a, dict)]


def _mercury_multipart(att_type: str, file_path: Path) -> Tuple[bytes, str]:
    """The exact wire shape `curl -F` produces: raw file bytes, no encoding.

    Built by hand rather than through `email`, which would base64 the payload
    and rewrite the line endings Mercury's parser expects.
    """
    boundary = "vgsmercury" + str(time.time_ns())
    # RFC 2183 filenames are quoted, so a name carrying a quote, a backslash or
    # a newline would end the header early and hand Mercury a body it would
    # read as something else. Percent-encoding those three is what curl does.
    file_name = (file_path.name.replace("\\", "%5C")
                 .replace('"', "%22")
                 .replace("\r", "").replace("\n", ""))
    ctype = mimetypes.guess_type(file_name)[0] or "application/octet-stream"
    head = (f"--{boundary}\r\n"
            f"Content-Disposition: form-data; name=\"attachmentType\"\r\n\r\n"
            f"{att_type}\r\n"
            f"--{boundary}\r\n"
            f"Content-Disposition: form-data; name=\"file\"; filename=\"{file_name}\"\r\n"
            f"Content-Type: {ctype}\r\n\r\n").encode("utf-8", "surrogateescape")
    tail = f"\r\n--{boundary}--\r\n".encode("ascii")
    return head + file_path.read_bytes() + tail, f"multipart/form-data; boundary={boundary}"


MERCURY_USAGE = (
    "Usage: vshell mercury snapshot [--days N] [--limit N]\n"
    "       vshell mercury check <transactionId>\n"
    "       vshell mercury upload <transactionId> <filePath> [--type receipt|other]\n"
    "       vshell mercury doctor\n"
    "       vshell mercury token-status | set-token (reads the key on stdin) | clear-token"
)


def _mercury_emit(sub: str, payload: Dict[str, Any]) -> int:
    """The one line of JSON a mercury run prints.

    Module level on purpose: CodeQL reads a nested emit as sharing the scope
    that held the API key and reports clear-text logging of it. Nothing here
    can reach that value -- the only key-adjacent field is `keySource`, a label
    reading "stored", "env" or "none" -- and hoisting the writer out of that
    scope is how the code says so rather than asking a reader to take it on
    trust. The field is `keySource` and not `tokenSource` for the same reason:
    the heuristic matches on the NAME, so a field called after the secret reads
    as the secret however plainly it is a label.
    """
    payload["source"] = "mercury"
    payload["kind"] = sub
    print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
    return 0


def _mercury_fail(sub: str, error: str, **extra: Any) -> int:
    """A failure still prints its JSON, and still exits nonzero.

    The widget reads stdout and ignores the status; a shell pipeline reads the
    status and would otherwise treat every failure as a success.
    """
    payload: Dict[str, Any] = {"ok": False, "error": error}
    payload.update(extra)
    _mercury_emit(sub, payload)
    return 1


def cmd_mercury(argv: List[str]) -> int:
    """Mercury banking snapshot, receipt upload and key management.

    Emits exactly one line of compact JSON per run, so the widget renders from
    a single parse and a failure is still a readable object rather than a
    traceback on stderr.

    The API token never travels on argv, where it would be visible to every
    process on the machine through /proc. It is read from the 0600 state file
    or from MERCURY_API_TOKEN, and it is never echoed back -- `token-status`
    reports the source only.
    """
    sub = argv[0] if argv else "snapshot"

    def emit(payload: Dict[str, Any]) -> int:
        return _mercury_emit(sub, payload)

    def fail(error: str, **extra: Any) -> int:
        return _mercury_fail(sub, error, **extra)

    if sub in {"-h", "--help", "help"}:
        eprint(MERCURY_USAGE)
        return 0
    if sub in {"-v", "--version"}:
        print("vshell-mercury 1.0.0")
        return 0

    # ---- key management: no network, no token needed -----------------------
    if sub == "token-status":
        return emit({"ok": True, "keySource": _mercury_key_source()})

    if sub == "set-token":
        # Read from stdin, never argv. One line: the caller writes the key and
        # a newline, so this returns without waiting for the stream to close.
        token = sys.stdin.readline().strip()
        if not token:
            return fail("no key was supplied on stdin")
        path = _mercury_token_path()
        try:
            path.parent.mkdir(parents=True, exist_ok=True)
            # Written through a 0600 temp file in the same directory and moved
            # into place, so the key is never briefly world-readable and a
            # crash mid-write cannot leave a truncated key behind.
            fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".mercury-token.")
            try:
                os.fchmod(fd, 0o600)
                with os.fdopen(fd, "w", encoding="utf-8") as handle:
                    handle.write(token + "\n")
                os.replace(tmp_name, str(path))
            except BaseException:
                with contextlib.suppress(OSError):
                    os.unlink(tmp_name)
                raise
            os.chmod(str(path), 0o600)
        except OSError as exc:
            return fail("could not save the key", detail=str(exc))
        return emit({"ok": True, "keySource": "stored"})

    if sub == "clear-token":
        try:
            _mercury_token_path().unlink()
        except FileNotFoundError:
            pass
        except OSError as exc:
            return fail("could not remove the stored key", detail=str(exc))
        return emit({"ok": True, "keySource": _mercury_key_source()})

    if sub not in {"snapshot", "check", "upload", "doctor"}:
        eprint(MERCURY_USAGE)
        return 2

    base = os.environ.get("MERCURY_API_BASE", MERCURY_API_DEFAULT_BASE).rstrip("/")
    token = _mercury_resolve_token()
    token_source = _mercury_key_source()
    if not token:
        return fail("no Mercury API key: add one in the widget settings, or set MERCURY_API_TOKEN",
                    keySource="none")

    def request(method: str, path: str, raw_body: Optional[bytes] = None,
                content_type: Optional[str] = None) -> Tuple[int, bytes]:
        return _mercury_request(base, token, method, path, raw_body, content_type)

    # ---- snapshot ----------------------------------------------------------
    if sub == "snapshot":
        days = 30
        limit = 20
        index = 1
        while index < len(argv):
            flag = argv[index]
            if flag in {"--days", "--limit"} and index + 1 < len(argv):
                try:
                    value = int(argv[index + 1])
                except ValueError:
                    return fail(f"{flag} needs a whole number")
                if flag == "--days":
                    days = max(1, min(365, value))
                else:
                    limit = max(1, min(500, value))
                index += 2
                continue
            return fail(f"unknown snapshot option: {flag}")

        # A fixed, generous cap of its own: tying this to --limit meant an
        # organisation with more accounts than the requested transaction count
        # summed only some of them, and the bar showed a total that was simply
        # wrong rather than obviously incomplete.
        acct_status, acct_body = request("GET", "/accounts?limit=500")
        if acct_status != 200:
            return fail(_mercury_reason("could not read accounts", acct_body, acct_status),
                        detail=_mercury_error_text(acct_body, acct_status),
                        status=acct_status, keySource=token_source)
        accounts_raw = (_mercury_json(acct_body) or {}).get("accounts") or []

        start = _dt.datetime.now(_dt.timezone.utc) - _dt.timedelta(days=days)
        # The trailing Z is required: without it Mercury answers 400
        # malformedDateParam. Statuses are repeated parameters, not a
        # comma-joined list, which is a different 400.
        query = ("/transactions?limit=" + str(limit) + "&order=desc"
                 + "".join("&status=" + s for s in MERCURY_TRANSACTION_STATUSES)
                 + "&start=" + urllib.parse.quote(start.strftime("%Y-%m-%dT%H:%M:%SZ")))
        # No accountId filter. Card accounts carry transactions but do not
        # appear in /accounts, so filtering on the known list silently dropped
        # every card transaction from the window.
        tx_status, tx_body = request("GET", query)
        if tx_status != 200:
            return fail(_mercury_reason("could not read transactions", tx_body, tx_status),
                        detail=_mercury_error_text(tx_body, tx_status),
                        status=tx_status, keySource=token_source)
        transactions_raw = (_mercury_json(tx_body) or {}).get("transactions") or []

        # The organisation name is decorative: a failure here must not cost the
        # user their balances, so it is fetched last and its status ignored.
        org_status, org_body = request("GET", "/organization")
        org_name = _mercury_org_name(org_body) if org_status == 200 else ""

        return emit({"ok": True,
                     "orgName": org_name,
                     "keySource": token_source,
                     "days": days,
                     "accounts": [_mercury_norm_account(a) for a in accounts_raw if isinstance(a, dict)],
                     "transactions": [_mercury_norm_transaction(t) for t in transactions_raw
                                      if isinstance(t, dict)]})

    # ---- doctor ------------------------------------------------------------
    if sub == "doctor":
        # One cheap call for the settings' Test button. It proves three things
        # at once: the key parses, the source address is whitelisted, and which
        # organisation the key actually belongs to.
        status, body = request("GET", "/organization")
        if status != 200:
            return fail(_mercury_reason("Mercury rejected the key", body, status),
                        detail=_mercury_error_text(body, status),
                        status=status, keySource=token_source)
        return emit({"ok": True, "orgName": _mercury_org_name(body), "keySource": token_source})

    # ---- check -------------------------------------------------------------
    if sub == "check":
        if len(argv) < 2:
            eprint("Usage: vshell mercury check <transactionId>")
            return 2
        tx_id = argv[1]
        status, body = request("GET", f"/transaction/{urllib.parse.quote(tx_id)}")
        if status != 200:
            return fail(_mercury_reason("could not read that transaction", body, status),
                        detail=_mercury_error_text(body, status),
                        status=status, transactionId=tx_id)
        data = _mercury_json(body) or {}
        transaction = data.get("transaction") or data
        attachments = transaction.get("attachments") if isinstance(transaction, dict) else None
        return emit({"ok": True, "transactionId": tx_id,
                     "hasReceipt": _mercury_has_receipt(attachments)})

    # ---- upload ------------------------------------------------------------
    if len(argv) < 3:
        eprint("Usage: vshell mercury upload <transactionId> <filePath> [--type receipt|other]")
        return 2
    tx_id = argv[1]
    file_path = Path(argv[2]).expanduser()
    att_type = "receipt"
    if "--type" in argv[3:]:
        type_index = argv.index("--type", 3)
        if type_index + 1 >= len(argv):
            return fail("--type needs a value")
        att_type = argv[type_index + 1]
    # Refused here rather than by Mercury: a typo would otherwise upload the
    # file under a type nothing recognises, and there is no way to take an
    # attachment back.
    if att_type not in MERCURY_ATTACHMENT_TYPES:
        return fail("unknown attachment type",
                    detail=f"{att_type} (expected: {', '.join(MERCURY_ATTACHMENT_TYPES)})")

    if not file_path.is_file():
        return fail("that file does not exist", detail=str(file_path))
    try:
        size = file_path.stat().st_size
    except OSError as exc:
        return fail("could not read that file", detail=str(exc))
    if size == 0:
        return fail("that file is empty", detail=str(file_path))
    if size > MERCURY_ATTACHMENT_MAX_BYTES:
        return fail("that file is over Mercury's 32 MiB attachment limit", detail=str(file_path))

    if att_type == "receipt":
        # Mercury has no endpoint to remove an attachment, so a duplicate
        # receipt is permanent. The widget only offers the upload when its
        # snapshot shows none, but that snapshot can be minutes old, so the
        # transaction is re-read immediately before the POST.
        #
        # A GATE, not a guard: this refuses unless the re-read positively says
        # there is no receipt. The two failures are not comparable -- a blocked
        # upload is retried in a second, a duplicate cannot be undone at all --
        # so an unreadable pre-check has to stop here, and it says which of the
        # two it is rather than claiming the receipt is already filed.
        pre_status, pre_body = request("GET", f"/transaction/{urllib.parse.quote(tx_id)}")
        if pre_status != 200:
            return fail(_mercury_reason("could not check for an existing receipt",
                                        pre_body, pre_status),
                        detail=_mercury_error_text(pre_body, pre_status),
                        status=pre_status, transactionId=tx_id)
        pre_data = _mercury_json(pre_body) or {}
        pre_tx = pre_data.get("transaction") or pre_data
        pre_atts = pre_tx.get("attachments") if isinstance(pre_tx, dict) else None
        if _mercury_has_receipt(pre_atts):
            return fail("a receipt is already attached to this transaction",
                        transactionId=tx_id, already=True)

    try:
        body_bytes, content_type = _mercury_multipart(att_type, file_path)
    except OSError as exc:
        return fail("could not read that file", detail=str(exc))

    status, body = request("POST", f"/transaction/{urllib.parse.quote(tx_id)}/attachments",
                           raw_body=body_bytes, content_type=content_type)
    if status not in {200, 201}:
        return fail(_mercury_reason("Mercury refused the attachment", body, status),
                    detail=_mercury_error_text(body, status),
                    status=status, transactionId=tx_id)
    return emit({"ok": True, "transactionId": tx_id, "fileName": file_path.name,
                 "attachments": _mercury_uploaded_attachments(body)})
