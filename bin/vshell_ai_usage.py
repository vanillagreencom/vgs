"""AI usage sources: where each provider's accounts come from, and the AI
Gateway provider itself.

Loaded by `vshell ai-usage`. It lives beside vshell-helper for the reason the
ratchet exists: the helper is already fifteen thousand lines, and a
self-contained subsystem that talks to one API is a seam, not a paragraph.
vshell_mercury.py and vshell_apps.py are the same shape.

Claude and Codex are found by looking for CLI logins on disk; the bash backend
bin/vshell-ai-usage owns that discovery and this module only records the extra
directories it should also look in. AI Gateway has no local login to find, so
it is configured with an API key and fetched from here.

AN API KEY NEVER TOUCHES argv, and never appears in a payload. It is read from
a 0600 file under the state directory or from AI_GATEWAY_API_KEY, and it
reaches exactly one place: the Authorization header in _request. The only
key-adjacent thing this module prints is a `source` label reading "stored" or
"env".
"""

from __future__ import annotations

import contextlib
import json
import os
import subprocess
import tempfile
import time
import urllib.parse
import urllib.request
from pathlib import Path
from typing import Any, Callable, Dict, List, Optional, Tuple


class AiUsageRuntime:
    """What this module needs from the host helper, passed in rather than
    imported: where local state and cache live, and how to report a problem."""

    def __init__(self, state_dir: Callable[[], Path], cache_dir: Callable[[], Path],
                 eprint: Callable[[str], None]) -> None:
        self.state_dir = state_dir
        self.cache_dir = cache_dir
        self.eprint = eprint


_RUNTIME: Optional[AiUsageRuntime] = None


def configure(runtime: AiUsageRuntime) -> None:
    global _RUNTIME
    _RUNTIME = runtime


def _runtime() -> AiUsageRuntime:
    if _RUNTIME is None:
        raise RuntimeError("vshell_ai_usage.configure() was never called")
    return _RUNTIME


# Provider ids, in the order the widget's catalog lists them. The widget owns
# display names and icons; this side owns how each one is found and fetched.
PROVIDERS = ("claude", "codex", "vercel")
# Providers configured with a key rather than by logging a CLI in.
KEY_PROVIDERS = ("vercel",)
# Providers whose accounts are config directories holding a CLI login.
DIR_PROVIDERS = ("claude", "codex")

AI_GATEWAY_BASE = "https://ai-gateway.vercel.sh/v1"
# Both are documented ways to authenticate an AI Gateway call, and a machine
# provisioned outside VGS may have either. A key typed into the widget wins.
AI_GATEWAY_ENV = ("AI_GATEWAY_API_KEY", "VERCEL_OIDC_TOKEN")
# The gateway is polled per bar instance, and a multi-monitor session has one
# per screen. Answers are shared through a short cache so the widget's own
# refresh interval is the only thing that decides how often the API is called.
GATEWAY_CACHE_TTL = 60.0
GATEWAY_TIMEOUT = 15.0

AI_USAGE_USAGE = (
    "Usage: vshell ai-usage <claude|codex|vercel>\n"
    "       vshell ai-usage sources <provider>\n"
    "       vshell ai-usage set-key <provider> [--label L] [--key-id K]  (reads the key on stdin)\n"
    "       vshell ai-usage clear-key <provider> <account-id>\n"
    "       vshell ai-usage add-dir <provider> <path>\n"
    "       vshell ai-usage remove-dir <provider> <path>"
)


# --- the source store --------------------------------------------------------


def sources_path() -> Path:
    """Where keys and extra config directories are kept.

    Deliberately NOT the plugin settings file: that lives under
    ~/.config/vshell, which operators routinely symlink into a dotfiles repo,
    and a key written there is one `git add` away from a public remote. This
    path is machine-local state, is never read by the settings serialiser, and
    the whole file is written 0600 because part of it is secret.
    """
    return _runtime().state_dir() / "ai-usage" / "sources.json"


def _read_store() -> Dict[str, Any]:
    try:
        data = json.loads(sources_path().read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return {"keys": {}, "dirs": {}}
    if not isinstance(data, dict):
        return {"keys": {}, "dirs": {}}
    keys = data.get("keys")
    dirs = data.get("dirs")
    return {"keys": keys if isinstance(keys, dict) else {},
            "dirs": dirs if isinstance(dirs, dict) else {}}


def _write_store(store: Dict[str, Any]) -> Optional[str]:
    """Replace the store atomically at 0600. Returns an error string, or None.

    Written through a 0600 temp file in the same directory and moved into
    place, so a key is never briefly world-readable and a crash mid-write
    cannot leave a truncated file behind.
    """
    path = sources_path()
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        with contextlib.suppress(OSError):
            os.chmod(str(path.parent), 0o700)
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".sources.")
        try:
            os.fchmod(fd, 0o600)
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump({"version": 1, "keys": store.get("keys", {}), "dirs": store.get("dirs", {})},
                          handle, indent=2, sort_keys=True)
                handle.write("\n")
            os.replace(tmp_name, str(path))
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp_name)
            raise
        os.chmod(str(path), 0o600)
    except OSError as exc:
        return str(exc)
    return None


def _stored_entries(provider: str) -> List[Dict[str, Any]]:
    raw = _read_store()["keys"].get(provider)
    if not isinstance(raw, list):
        return []
    out = []
    for item in raw:
        if not isinstance(item, dict):
            continue
        key = str(item.get("key") or "")
        if not key:
            continue
        out.append({"id": str(item.get("id") or ""), "label": str(item.get("label") or ""),
                    "key": key, "keyId": str(item.get("keyId") or "")})
    return [e for e in out if e["id"]]


def extra_dirs(provider: str) -> List[str]:
    raw = _read_store()["dirs"].get(provider)
    if not isinstance(raw, list):
        return []
    return [str(p) for p in raw if isinstance(p, str) and p.strip()]


def _entry_id(label: str, existing: List[str]) -> str:
    """A stable id for a new credential entry.

    Derived from the label so the file stays readable, never from the key. A
    label the user reuses gets a suffix rather than overwriting the entry that
    already has it: two keys with the same name are two accounts.
    """
    base = "".join(c if c.isalnum() or c in "-_" else "-" for c in label.strip().lower()).strip("-")
    base = base or "key"
    if base not in existing:
        return base
    for n in range(2, 100):
        candidate = f"{base}-{n}"
        if candidate not in existing:
            return candidate
    return f"{base}-{int(time.time())}"


# --- credential resolution ---------------------------------------------------


def _env_key() -> Tuple[str, str]:
    """The API key provisioned outside VGS, and the variable it came from."""
    for name in AI_GATEWAY_ENV:
        value = os.environ.get(name, "").strip()
        if value:
            return value, name
    return "", ""


def gateway_credentials() -> List[Dict[str, Any]]:
    """Every AI Gateway credential, keys included, in display order.

    A key typed into the widget comes first, because that is the one the user
    can see and change from the shell. The environment is the fallback for a
    key a secret manager wrote, which the user may never open settings for.
    """
    out: List[Dict[str, Any]] = []
    for entry in _stored_entries("vercel"):
        out.append({"id": entry["id"], "label": entry["label"] or entry["id"],
                    "key": entry["key"], "keyId": entry["keyId"], "source": "stored"})
    env_value, env_name = _env_key()
    if env_value:
        out.append({"id": "env", "label": env_name, "key": env_value, "keyId": "", "source": "env"})
    return out


# --- HTTP --------------------------------------------------------------------


def _request(path: str, key: str, query: Optional[Dict[str, str]] = None) -> Tuple[int, bytes]:
    """One AI Gateway call. Returns (status, body); never raises.

    Every transport failure becomes a synthetic status 0 whose body is the
    reason, so callers always emit JSON rather than a traceback.
    """
    from urllib.error import HTTPError, URLError

    url = AI_GATEWAY_BASE + path
    if query:
        url += "?" + urllib.parse.urlencode(query)
    req = urllib.request.Request(url, method="GET", headers={
        "Authorization": "Bearer " + key,
        "User-Agent": "vshell-ai-usage",
        "Accept": "application/json",
    })
    try:
        with urllib.request.urlopen(req, timeout=GATEWAY_TIMEOUT) as resp:
            return resp.status, resp.read()
    except HTTPError as exc:
        return exc.code, exc.read()
    except URLError as exc:
        return 0, str(getattr(exc, "reason", exc)).encode("utf-8", "replace")
    except (TimeoutError, OSError) as exc:
        # A read timeout surfaces as a bare TimeoutError, not inside URLError.
        return 0, str(exc).encode("utf-8", "replace")


def _json_body(body: bytes) -> Any:
    try:
        return json.loads(body.decode("utf-8", "replace"))
    except ValueError:
        return None


def _trim(message: str) -> str:
    """One readable sentence for a card that is a few hundred pixels wide.

    The gateway appends a percent-encoded dashboard link to its auth errors,
    which is longer than the message and unreadable in a bar flyout, so the
    text stops where the link begins.
    """
    text = " ".join(message.split())
    for marker in (" http://", " https://"):
        at = text.find(marker)
        if at != -1:
            # Drop the colon or dash that was introducing the link too.
            text = text[:at].rstrip(" :;,-")
    return text if len(text) <= 200 else text[:199] + "…"


def _error_text(status: int, body: bytes) -> str:
    """The most specific sentence available for a failed call."""
    data = _json_body(body)
    if isinstance(data, dict):
        for field in ("error", "message", "detail"):
            value = data.get(field)
            if isinstance(value, dict):
                value = value.get("message")
            if isinstance(value, str) and value.strip():
                return _trim(value)
    if status == 0:
        return _trim(body.decode("utf-8", "replace")) or "network error"
    if status in (401, 403):
        return f"the API key was refused (HTTP {status})"
    return f"AI Gateway returned HTTP {status}"


# --- the AI Gateway provider -------------------------------------------------


def _cache_file(entry_id: str) -> Path:
    safe = "".join(c if c.isalnum() or c in "-_" else "_" for c in entry_id) or "entry"
    return _runtime().cache_dir() / "ai-usage" / f"vercel-{safe}.json"


def _read_cache(entry_id: str) -> Optional[Dict[str, Any]]:
    path = _cache_file(entry_id)
    try:
        if time.time() - path.stat().st_mtime > GATEWAY_CACHE_TTL:
            return None
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, ValueError):
        return None
    return data if isinstance(data, dict) else None


def _write_cache(entry_id: str, account: Dict[str, Any]) -> None:
    path = _cache_file(entry_id)
    try:
        path.parent.mkdir(parents=True, exist_ok=True)
        fd, tmp_name = tempfile.mkstemp(dir=str(path.parent), prefix=".vercel-")
        try:
            with os.fdopen(fd, "w", encoding="utf-8") as handle:
                json.dump(account, handle)
            os.replace(tmp_name, str(path))
        except BaseException:
            with contextlib.suppress(OSError):
                os.unlink(tmp_name)
            raise
    except OSError:
        # A cache that cannot be written costs an API call, not an answer.
        pass


def _money(amount: float) -> str:
    return f"${amount:,.2f}"


def _pct(used: float, limit: float) -> int:
    if limit <= 0:
        return 0
    return max(0, min(100, round(100.0 * used / limit)))


def _number(value: Any) -> Optional[float]:
    """A JSON number or a numeric string as a float. The credits endpoint
    reports amounts as strings and the quotas endpoint as numbers."""
    if isinstance(value, bool) or value is None:
        return None
    if isinstance(value, (int, float)):
        return float(value)
    try:
        return float(str(value).strip())
    except ValueError:
        return None


def _quota_lane(entry: Dict[str, Any]) -> Tuple[Optional[Dict[str, Any]], str]:
    """The budget on this key, when one is configured and readable.

    The quotas endpoint is addressed by key ID, which the key itself does not
    carry, so this runs only when the user supplied one. A key with no budget
    answers 404, which is an absence rather than a fault.
    """
    key_id = entry.get("keyId") or ""
    if not key_id:
        return None, ""
    status, body = _request("/quotas", entry["key"],
                            {"quotaEntityId": "api_key_id_" + str(key_id)})
    if status == 404:
        return None, ""
    if status != 200:
        return None, _error_text(status, body)
    data = _json_body(body)
    if not isinstance(data, dict) or data.get("active") is not True:
        return None, ""
    limit = _number(data.get("limitAmount"))
    spent = _number(data.get("currentSpend")) or 0.0
    if limit is None or limit <= 0:
        return None, ""
    period = str(data.get("refreshPeriod") or "").strip()
    return {
        "label": f"Budget ({period})" if period else "Budget",
        "pct": _pct(spent, limit),
        "used": spent,
        "limit": limit,
        "currency": "USD",
        "detail": f"{_money(spent)} of {_money(limit)}",
        "apiKeyName": str(data.get("apiKeyName") or ""),
    }, ""


def _gateway_account(entry: Dict[str, Any]) -> Dict[str, Any]:
    """One AI Gateway credential as an account entry the widget can render."""
    cached = _read_cache(entry["id"])
    if cached is not None:
        return cached

    account: Dict[str, Any] = {
        "id": entry["id"],
        "label": entry["label"] or entry["id"],
        "ok": False,
        "plan": "",
        "class": "low",
        "session": None,
        "weekly": None,
        "models": [],
        "spend": None,
        "enterprise": False,
        "error": "",
    }

    status, body = _request("/credits", entry["key"])
    if status != 200:
        account["error"] = _error_text(status, body)
        # A refused key is worth re-asking soon; nothing is cached for it.
        return account
    data = _json_body(body)
    if not isinstance(data, dict):
        account["error"] = "AI Gateway returned unreadable credit data"
        return account

    balance = _number(data.get("balance"))
    used = _number(data.get("total_used"))
    if balance is None and used is None:
        account["error"] = "AI Gateway reported no credit balance"
        return account
    balance = 0.0 if balance is None else balance
    used = 0.0 if used is None else used

    quota, quota_error = _quota_lane(entry)
    # The pool a prepaid balance is measured against is everything that was
    # ever put in it: spent plus what is left. Lifetime spend on its own has no
    # denominator and cannot be a percentage of anything.
    pool = balance + used
    credits_lane = {
        "label": "Credits",
        "pct": _pct(used, pool),
        "used": used,
        "limit": pool,
        "currency": "USD",
        "detail": f"{_money(balance)} left of {_money(pool)}",
    }

    account["ok"] = True
    account["plan"] = _money(balance) + " left"
    if quota is not None:
        # A budget is the tighter, more actionable limit, so it takes the spend
        # lane and the prepaid pool becomes a second row rather than vanishing.
        account["label"] = entry["label"] or quota.get("apiKeyName") or entry["id"]
        account["spend"] = {k: v for k, v in quota.items() if k != "apiKeyName"}
        account["models"] = [{"label": credits_lane["label"], "pct": credits_lane["pct"],
                              "reset": "", "resetAt": 0, "detail": credits_lane["detail"]}]
    else:
        account["spend"] = credits_lane
        if quota_error:
            # The budget lookup failed but the balance did not. Say so on the
            # card rather than dropping the account or the reason.
            account["models"] = [{"label": "Budget", "pct": 0, "reset": "", "resetAt": 0,
                                  "detail": "budget unavailable: " + quota_error}]

    peak = max([lane["pct"] for lane in ([account["spend"]] if account["spend"] else [])]
               + [m.get("pct", 0) for m in account["models"]] + [0])
    account["class"] = ("critical" if peak >= 90 else "high" if peak >= 75
                        else "mid" if peak >= 50 else "low")
    _write_cache(entry["id"], account)
    return account


def gateway_payload() -> Dict[str, Any]:
    """The AI Gateway provider payload, in the shape every provider answers in."""
    credentials = gateway_credentials()
    if not credentials:
        return {
            "ok": False,
            "configured": False,
            "error": "No AI Gateway API key yet. Add one to track credits and budgets.",
            "accounts": [],
        }
    accounts = [_gateway_account(entry) for entry in credentials]
    live = [a for a in accounts if a["ok"]]
    if not live:
        return {"ok": False, "configured": True,
                "error": accounts[0].get("error") or "usage unavailable",
                "accounts": accounts}
    peaks = []
    for account in live:
        lanes = [account["spend"]["pct"]] if account["spend"] else []
        lanes += [m.get("pct", 0) for m in account["models"]]
        peaks.append(max(lanes) if lanes else 0)
    aggregate = round(sum(peaks) / len(peaks)) if peaks else 0
    return {
        "ok": True,
        "configured": True,
        "plan": live[0]["plan"],
        "class": ("critical" if aggregate >= 90 else "high" if aggregate >= 75
                  else "mid" if aggregate >= 50 else "low"),
        "accounts": accounts,
        "aggregate": {"count": len(live), "total": len(accounts), "pct": aggregate},
    }


# --- sources reporting -------------------------------------------------------


def _backend_dirs(provider: str, backend: str) -> Tuple[List[Dict[str, Any]], str]:
    """Ask the discovery backend which config directories it would use.

    Discovery lives in bin/vshell-ai-usage, which is also what fetches those
    directories. Reimplementing it here would let the page report directories
    the fetch does not read, or miss ones it does.
    """
    if not backend:
        return [], "ai-usage backend not found"
    proc = subprocess.run([backend, "--dirs", provider], text=True,
                          stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if proc.returncode != 0:
        return [], proc.stderr.strip() or "could not list config directories"
    try:
        payload = json.loads(proc.stdout.strip() or "{}")
    except ValueError:
        return [], "the ai-usage backend returned unreadable directory data"
    dirs = payload.get("dirs")
    return (dirs if isinstance(dirs, list) else []), ""


def sources_report(provider: str, backend: str) -> Dict[str, Any]:
    """What this provider's setup page shows: never a key, only its source."""
    if provider not in PROVIDERS:
        return {"ok": False, "provider": provider, "error": f"unknown provider: {provider}"}
    report: Dict[str, Any] = {
        "ok": True,
        "provider": provider,
        "takesKey": provider in KEY_PROVIDERS,
        "accounts": [],
        "dirs": [],
    }
    if provider in KEY_PROVIDERS:
        # An environment-provisioned key is listed as an account like any other,
        # labelled by the variable it came from, so the page shows one list of
        # sources rather than a list plus a separate flag about a hidden one.
        report["accounts"] = [
            {"id": entry["id"], "label": entry["label"], "source": entry["source"],
             "hasKeyId": bool(entry["keyId"])}
            for entry in gateway_credentials()
        ]
        return report
    dirs, error = _backend_dirs(provider, backend)
    report["dirs"] = dirs
    if error:
        report["ok"] = False
        report["error"] = error
    return report


# --- mutations ---------------------------------------------------------------


def set_key(provider: str, key: str, label: str, key_id: str) -> Dict[str, Any]:
    if provider not in KEY_PROVIDERS:
        return {"ok": False, "error": f"{provider} is not configured with an API key"}
    if not key:
        return {"ok": False, "error": "no key was supplied on stdin"}
    store = _read_store()
    entries = store["keys"].get(provider)
    entries = [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []
    entry_id = _entry_id(label or provider, [str(e.get("id") or "") for e in entries])
    entries.append({"id": entry_id, "label": label, "key": key, "keyId": key_id})
    store["keys"][provider] = entries
    failure = _write_store(store)
    if failure:
        return {"ok": False, "error": "could not save the key", "detail": failure}
    return {"ok": True, "id": entry_id, "source": "stored"}


def clear_key(provider: str, entry_id: str) -> Dict[str, Any]:
    if provider not in KEY_PROVIDERS:
        return {"ok": False, "error": f"{provider} is not configured with an API key"}
    store = _read_store()
    entries = store["keys"].get(provider)
    entries = [e for e in entries if isinstance(e, dict)] if isinstance(entries, list) else []
    kept = [e for e in entries if str(e.get("id") or "") != entry_id]
    if len(kept) == len(entries):
        # An id that is not stored is either the environment's entry or already
        # gone. Reporting a removal for either would be a claim about a key
        # this side goes on reading.
        return {"ok": False, "error": "that key is not one VGS stores"}
    store["keys"][provider] = kept
    failure = _write_store(store)
    if failure:
        return {"ok": False, "error": "could not remove the key", "detail": failure}
    _cache_file(entry_id).unlink(missing_ok=True)
    return {"ok": True}


def _normalize_dir(path: str) -> str:
    return str(Path(os.path.expanduser(path.strip())).absolute()).rstrip("/")


def add_dir(provider: str, path: str) -> Dict[str, Any]:
    if provider not in DIR_PROVIDERS:
        return {"ok": False, "error": f"{provider} does not read config directories"}
    resolved = _normalize_dir(path)
    if not resolved:
        return {"ok": False, "error": "no directory was given"}
    if not Path(resolved).is_dir():
        return {"ok": False, "error": f"{resolved} is not a directory"}
    store = _read_store()
    current = [p for p in (store["dirs"].get(provider) or []) if isinstance(p, str)]
    if resolved in current:
        return {"ok": True, "path": resolved}
    current.append(resolved)
    store["dirs"][provider] = current
    failure = _write_store(store)
    if failure:
        return {"ok": False, "error": "could not save the directory", "detail": failure}
    return {"ok": True, "path": resolved}


def remove_dir(provider: str, path: str) -> Dict[str, Any]:
    if provider not in DIR_PROVIDERS:
        return {"ok": False, "error": f"{provider} does not read config directories"}
    resolved = _normalize_dir(path)
    store = _read_store()
    current = [p for p in (store["dirs"].get(provider) or []) if isinstance(p, str)]
    kept = [p for p in current if p != resolved and p != path.strip()]
    if len(kept) == len(current):
        return {"ok": False, "error": "that directory was not one VGS was told to look in"}
    store["dirs"][provider] = kept
    failure = _write_store(store)
    if failure:
        return {"ok": False, "error": "could not remove the directory", "detail": failure}
    return {"ok": True}
