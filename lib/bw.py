#!/usr/bin/env python3
"""Bitwarden CLI wrapper + identity/profile discovery.

Replaces lib/bw-session.sh and the bash bw_* helpers in lib/common.sh.
Components (linux.sh / windows.ps1) still source those for their own bw
operations — this module is for the bootstrap orchestrator.
"""
from __future__ import annotations
import getpass, json, os, re, shutil, subprocess, sys
from pathlib import Path


IDENTITY_PREFIX = "Machine Identity: "
PROFILE_PREFIX  = "Machine Profile: "


def _log(msg: str) -> None:
    print(f"==> {msg}", file=sys.stderr, flush=True)

def _warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr, flush=True)


def have_bw() -> bool:
    return shutil.which("bw") is not None


def status() -> dict:
    """Returns parsed `bw status` JSON, or {} if bw is unavailable/errors."""
    if not have_bw():
        return {}
    try:
        result = subprocess.run(["bw", "status"], capture_output=True, text=True, check=False)
        if result.returncode != 0 or not result.stdout.strip():
            return {}
        return json.loads(result.stdout)
    except (json.JSONDecodeError, OSError):
        return {}


def is_unlocked() -> bool:
    """True if BW_SESSION is set and bw status reports unlocked."""
    if not os.environ.get("BW_SESSION"):
        return False
    return status().get("status") == "unlocked"


def unlock(password_prompt: str = "Bitwarden master password") -> bool:
    """Make sure the vault is unlocked. Returns True on success.

    Order of attempts:
      1. existing BW_SESSION (verified via status)
      2. login (if vault is unauthenticated)
      3. unlock with BW_PASSWORD env, else interactive prompt
    On success, BW_SESSION is set in os.environ.
    """
    if not have_bw():
        _warn("bw CLI not installed; skipping vault unlock")
        return False

    if is_unlocked():
        _log("Bitwarden session already active.")
        sync()
        return True

    st = status()
    if st.get("status") == "unauthenticated":
        _log("Logging in to Bitwarden...")
        rc = subprocess.call(["bw", "login"])
        if rc != 0:
            _warn("Bitwarden login failed")
            return False

    pw = os.environ.get("BW_PASSWORD")
    if not pw:
        try:
            pw = getpass.getpass(f"{password_prompt}: ")
        except (EOFError, KeyboardInterrupt):
            _warn("\nUnlock cancelled")
            return False
    if not pw:
        _warn("No password supplied")
        return False

    proc = subprocess.run(
        ["bw", "unlock", "--passwordenv", "_BW_PWD_TMP", "--raw"],
        capture_output=True, text=True,
        env={**os.environ, "_BW_PWD_TMP": pw},
    )
    if proc.returncode != 0 or not proc.stdout.strip():
        _warn("Bitwarden unlock failed")
        return False
    os.environ["BW_SESSION"] = proc.stdout.strip()
    sync()
    return True


def sync() -> None:
    """Best-effort `bw sync` (so newly added items show up)."""
    if not have_bw():
        return
    _log("Syncing Bitwarden vault...")
    subprocess.call(["bw", "sync"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)


def list_items() -> list[dict]:
    """All vault items as parsed JSON list. Returns [] on any failure."""
    if not is_unlocked():
        return []
    proc = subprocess.run(["bw", "list", "items"], capture_output=True, text=True)
    if proc.returncode != 0 or not proc.stdout.strip():
        return []
    try:
        data = json.loads(proc.stdout)
        return data if isinstance(data, list) else []
    except json.JSONDecodeError:
        _warn("bw list items returned non-JSON output")
        return []


def get_item_exact(name: str) -> dict | None:
    """Find a vault item by exact name (case-sensitive). bw's substring match
    is too loose — `bw get item 'Machine SSH Key'` also returns 'Machine SSH
    Key Work'."""
    for item in list_items():
        if item.get("name") == name:
            return item
    return None


def encode_and_create(payload: dict) -> str | None:
    """Pipe payload JSON through `bw encode | bw create item`. Returns the
    new item ID on success, None on failure."""
    encoded = subprocess.run(
        ["bw", "encode"], input=json.dumps(payload), capture_output=True, text=True
    )
    if encoded.returncode != 0:
        return None
    created = subprocess.run(
        ["bw", "create", "item"], input=encoded.stdout, capture_output=True, text=True
    )
    if created.returncode != 0:
        _warn(f"bw create failed: {created.stderr.strip()}")
        return None
    try:
        return json.loads(created.stdout).get("id")
    except json.JSONDecodeError:
        return None


def encode_and_edit(item_id: str, payload: dict) -> bool:
    encoded = subprocess.run(
        ["bw", "encode"], input=json.dumps(payload), capture_output=True, text=True
    )
    if encoded.returncode != 0:
        return False
    edited = subprocess.run(
        ["bw", "edit", "item", item_id], input=encoded.stdout, capture_output=True, text=True
    )
    return edited.returncode == 0


# ── Discovery ───────────────────────────────────────────────────────────────

def discover_identities() -> dict:
    """Return {name: identity-dict} for every "Machine Identity: <name>" item.

    Each identity dict mirrors the TOML-loaded shape: name, git_name,
    git_email, ssh_key_basename, default, applies_to, plus bw_ssh_item
    pointing back at this same item (so the ssh-key component can find
    private/public keys in the same place).
    """
    if not is_unlocked():
        return {}
    items = list_items()
    if not items:
        return {}
    registry: dict[str, dict] = {}
    for item in items:
        name = item.get("name") or ""
        if not name.startswith(IDENTITY_PREFIX):
            continue
        ident_name = name[len(IDENTITY_PREFIX):].strip()
        if not ident_name:
            continue
        fields = {f.get("name"): f.get("value") for f in (item.get("fields") or [])}
        applies_to: list[dict] = []
        raw_at = fields.get("applies_to_json", "")
        if raw_at:
            try:
                parsed = json.loads(raw_at)
                if isinstance(parsed, list):
                    applies_to = parsed
            except json.JSONDecodeError:
                pass
        registry[ident_name] = {
            "name":             ident_name,
            "git_name":         fields.get("git_name", ""),
            "git_email":        fields.get("git_email", ""),
            "ssh_key_basename": fields.get("ssh_key_basename") or f"id_ed25519_{ident_name}",
            "bw_ssh_item":      name,
            "default":          (fields.get("default") or "").strip().lower() == "true",
            "applies_to":       applies_to,
        }
    return registry


def write_identity_registry(path: Path | str, registry: dict | None = None) -> None:
    """Discover (or use provided) identities and write to a JSON registry
    file. The path is what config.py reads via MACHINE_SETUP_IDENTITY_REGISTRY.
    """
    if registry is None:
        registry = discover_identities()
    Path(path).write_text(json.dumps(registry, indent=2))
    if registry:
        _log(f"Discovered {len(registry)} identity item(s) in Bitwarden: {', '.join(sorted(registry.keys()))}")
    else:
        _log("No 'Machine Identity: *' items found in Bitwarden")


def discover_profiles(cache_dir: Path | str) -> int:
    """Find `Machine Profile: <name>` BW items and write each note body to
    <cache_dir>/profiles/<name>.toml. Returns count.

    Profiles are LEGACY now (we migrated away from them) but we keep
    discovery so users with old BW items see them surface for migration.
    """
    out = Path(cache_dir) / "profiles"
    out.mkdir(parents=True, exist_ok=True)
    if not is_unlocked():
        return 0
    items = list_items()
    name_re = re.compile(r"^[A-Za-z0-9_-]+$")
    count = 0
    for item in items:
        name = item.get("name") or ""
        if not name.startswith(PROFILE_PREFIX):
            continue
        prof_name = name[len(PROFILE_PREFIX):].strip()
        if not prof_name or not name_re.fullmatch(prof_name):
            continue
        body = (item.get("notes") or "").strip()
        if not body:
            continue
        (out / f"{prof_name}.toml").write_text(body + "\n")
        count += 1
    return count
