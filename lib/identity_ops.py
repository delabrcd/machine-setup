#!/usr/bin/env python3
"""Identity creation + migration helpers.

Used by:
  - the bootstrap wizard (lib/main.py) when user picks [+] Create new identity
  - tools/seed-bw-identity.py (CLI wrapper for the same logic)
  - tools/migrate-to-bw.py
"""
from __future__ import annotations
import json, os, stat, subprocess, sys, tempfile, tomllib
from pathlib import Path

import bw  # sibling module


def _log(msg: str) -> None:
    print(f"==> {msg}", file=sys.stderr, flush=True)

def _warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr, flush=True)


def _gen_ed25519_keypair(comment: str) -> tuple[str, str]:
    """Run ssh-keygen, return (private, public). The temp dir is wiped before
    we return — the keys never persist on disk past this function."""
    with tempfile.TemporaryDirectory() as d:
        keyfile = Path(d) / "id_ed25519"
        rc = subprocess.call(
            ["ssh-keygen", "-t", "ed25519", "-C", comment, "-f", str(keyfile), "-N", ""],
            stdin=subprocess.DEVNULL,
        )
        if rc != 0:
            raise RuntimeError("ssh-keygen failed")
        priv = keyfile.read_text()
        pub  = (keyfile.with_suffix(".pub")).read_text()
    return priv, pub


def _bw_template_item() -> dict:
    """`bw get template item` output as a dict."""
    proc = subprocess.run(["bw", "get", "template", "item"], capture_output=True, text=True)
    if proc.returncode != 0:
        raise RuntimeError(f"bw get template failed: {proc.stderr.strip()}")
    return json.loads(proc.stdout)


def upsert_identity(
    name: str,
    *,
    git_name: str,
    git_email: str,
    ssh_key_basename: str | None = None,
    is_default: bool = False,
    applies_to: list[dict] | None = None,
    private_key: str = "",
    public_key: str = "",
) -> bool:
    """Create or update the `Machine Identity: <name>` BW item with all
    metadata + (optional) SSH key fields. Returns True on success.
    """
    item_name = f"Machine Identity: {name}"
    ssh_basename = ssh_key_basename or f"id_ed25519_{name}"
    applies_to_json = json.dumps(applies_to or [])

    desired_fields = [
        {"name": "git_name",         "value": git_name,         "type": 0},
        {"name": "git_email",        "value": git_email,        "type": 0},
        {"name": "ssh_key_basename", "value": ssh_basename,     "type": 0},
        {"name": "default",          "value": "true" if is_default else "false", "type": 0},
        {"name": "applies_to_json",  "value": applies_to_json,  "type": 0},
    ]
    if public_key:
        desired_fields.append({"name": "public_key",  "value": public_key,  "type": 0})
    if private_key:
        desired_fields.append({"name": "private_key", "value": private_key, "type": 1})

    existing = bw.get_item_exact(item_name)
    if existing:
        _log(f"Updating existing item: {item_name}")
        # Merge: preserve non-overridden fields, replace ours
        by_name = {f.get("name"): f for f in (existing.get("fields") or [])}
        for d in desired_fields:
            if d["name"] in by_name:
                by_name[d["name"]]["value"] = d["value"]
                by_name[d["name"]]["type"]  = d["type"]
            else:
                existing.setdefault("fields", []).append(d)
        return bw.encode_and_edit(existing["id"], existing)
    else:
        _log(f"Creating new item: {item_name}")
        template = _bw_template_item()
        template.update({
            "type":       2,
            "name":       item_name,
            "secureNote": {"type": 0},
            "fields":     desired_fields,
        })
        return bw.encode_and_create(template) is not None


def get_ssh_from_item(item_name: str) -> tuple[str, str] | None:
    """Read private + public key fields from an existing BW item by exact
    name. Returns (priv, pub) or None if not found / no fields."""
    item = bw.get_item_exact(item_name)
    if not item:
        return None
    fields = {f.get("name"): f.get("value") for f in (item.get("fields") or [])}
    priv = fields.get("private_key", "") or ""
    pub  = fields.get("public_key", "")  or ""
    if not (priv or pub):
        return None
    return priv, pub


def create_identity_interactive(
    *,
    name: str,
    git_name: str,
    git_email: str,
    is_default: bool,
    host: str,
    credential_helper: str,
) -> bool:
    """Wizard-driven create: generates ed25519, builds applies_to, upserts in BW,
    prints public key for registration, pauses for ENTER.
    """
    applies_to: list[dict] = []
    if host:
        applies_to.append({
            "host": host,
            "git_url_patterns": [f"git@{host}:*/*", f"https://{host}/*/*"],
            "credential_helper": credential_helper or "ssh",
        })

    _log("Generating ed25519 SSH key...")
    priv, pub = _gen_ed25519_keypair(comment=git_email or name)

    ok = upsert_identity(
        name,
        git_name=git_name,
        git_email=git_email,
        is_default=is_default,
        applies_to=applies_to,
        private_key=priv,
        public_key=pub,
    )
    if not ok:
        _warn("Failed to upsert identity in Bitwarden")
        return False

    print("", file=sys.stderr)
    print("Public key (register on the relevant service):", file=sys.stderr)
    print("", file=sys.stderr)
    print(pub.rstrip(), file=sys.stderr)
    print("", file=sys.stderr)
    try:
        if sys.stdin.isatty():
            input("Press ENTER once the key is registered: ")
        else:
            with open("/dev/tty", "r") as tty:
                sys.stderr.write("Press ENTER once the key is registered: ")
                sys.stderr.flush()
                tty.readline()
    except (EOFError, KeyboardInterrupt, OSError):
        pass
    return True


def read_identity(name: str) -> dict | None:
    """Read a Machine Identity item from BW into a dict suitable for the
    edit form (name, git_name, git_email, ssh_key_basename, default,
    applies_to, private_key, public_key). None if the item doesn't exist.
    """
    item = bw.get_item_exact(f"Machine Identity: {name}")
    if not item:
        return None
    fields = {f.get("name"): f.get("value") for f in (item.get("fields") or [])}
    applies_to: list[dict] = []
    raw = fields.get("applies_to_json", "")
    if raw:
        try:
            parsed = json.loads(raw)
            if isinstance(parsed, list):
                applies_to = parsed
        except json.JSONDecodeError:
            pass
    return {
        "name":             name,
        "git_name":         fields.get("git_name", ""),
        "git_email":        fields.get("git_email", ""),
        "ssh_key_basename": fields.get("ssh_key_basename") or f"id_ed25519_{name}",
        "default":          (fields.get("default") or "").strip().lower() == "true",
        "applies_to":       applies_to,
        "private_key":      fields.get("private_key", "") or "",
        "public_key":       fields.get("public_key", "") or "",
    }


def list_identity_names() -> list[str]:
    """All Machine Identity item names currently in BW (post-prefix)."""
    out: list[str] = []
    for item in bw.list_items():
        name = item.get("name") or ""
        if name.startswith("Machine Identity: "):
            out.append(name[len("Machine Identity: "):].strip())
    return sorted(set(filter(None, out)))


# ── MCP Secrets item ────────────────────────────────────────────────────────

MCP_SECRETS_ITEM = "Claude Code MCP Secrets"

# (field_name, hidden, label, placeholder)
MCP_SECRETS_FIELDS: list[tuple[str, bool, str, str]] = [
    ("context7_api_key",     True,  "context7 API key",                "ctx7_..."),
    ("bitbucket_email",      False, "Bitbucket account email",         "you@example.com"),
    ("bitbucket_api_token",  True,  "Bitbucket API token (scoped)",    "ATATT..."),
    ("bitbucket_workspace",  False, "Bitbucket workspace slug",        "your-workspace"),
    ("jira_url",             False, "Jira server URL",                 "https://jira.example.com"),
    ("jira_pat",             True,  "Jira PAT",                        "..."),
]


def read_mcp_secrets() -> dict[str, str]:
    """Return current values for every known MCP-secrets field. Missing
    item / missing fields → empty string."""
    item = bw.get_item_exact(MCP_SECRETS_ITEM)
    if not item:
        return {name: "" for name, _h, _l, _p in MCP_SECRETS_FIELDS}
    fields = {f.get("name"): f.get("value") for f in (item.get("fields") or [])}
    return {name: fields.get(name, "") or "" for name, _h, _l, _p in MCP_SECRETS_FIELDS}


def write_mcp_secrets(values: dict[str, str]) -> bool:
    """Create or update the Claude Code MCP Secrets BW item with the given
    field values. Empty strings are still written (overwrites stale data
    deterministically). Returns True on success."""
    existing = bw.get_item_exact(MCP_SECRETS_ITEM)
    desired = []
    for name, hidden, _label, _placeholder in MCP_SECRETS_FIELDS:
        desired.append({
            "name":  name,
            "value": values.get(name, "") or "",
            "type":  1 if hidden else 0,
        })

    if existing:
        _log(f"Updating BW item: {MCP_SECRETS_ITEM}")
        by_name = {f.get("name"): f for f in (existing.get("fields") or [])}
        for d in desired:
            if d["name"] in by_name:
                by_name[d["name"]]["value"] = d["value"]
                by_name[d["name"]]["type"]  = d["type"]
            else:
                existing.setdefault("fields", []).append(d)
        return bw.encode_and_edit(existing["id"], existing)
    else:
        _log(f"Creating BW item: {MCP_SECRETS_ITEM}")
        template = _bw_template_item()
        template.update({
            "type":       2,
            "name":       MCP_SECRETS_ITEM,
            "secureNote": {"type": 0},
            "fields":     desired,
        })
        return bw.encode_and_create(template) is not None


# ── Claude Code global config (CLAUDE.md content) ──────────────────────────
#
# Stored as the BW item's free-form `notes` field (which is naturally
# multi-line). The chezmoi component reads this back at apply time and
# writes ~/.claude/CLAUDE.md so Bitwarden is the source of truth for
# personal global instructions.

CLAUDE_CONFIG_ITEM = "Claude Code Global Config"


def read_claude_md() -> str:
    """Return the notes field of the global-config item, or '' if missing."""
    item = bw.get_item_exact(CLAUDE_CONFIG_ITEM)
    if not item:
        return ""
    return (item.get("notes") or "")


def write_claude_md(content: str) -> bool:
    """Create-or-update the global-config item with `content` in its notes
    field. Returns True on success."""
    existing = bw.get_item_exact(CLAUDE_CONFIG_ITEM)
    if existing:
        _log(f"Updating BW item: {CLAUDE_CONFIG_ITEM}")
        existing["notes"] = content
        return bw.encode_and_edit(existing["id"], existing)
    else:
        _log(f"Creating BW item: {CLAUDE_CONFIG_ITEM}")
        template = _bw_template_item()
        template.update({
            "type":       2,
            "name":       CLAUDE_CONFIG_ITEM,
            "secureNote": {"type": 0},
            "notes":      content,
        })
        return bw.encode_and_create(template) is not None


# ── SSH key import (existing key into a Machine Identity item) ──────────────

def import_ssh_key_text(name: str, private_key: str, public_key: str) -> bool:
    """Update an existing Machine Identity: <name> item's private_key /
    public_key fields with provided text. Errors if the item doesn't exist.
    """
    item = bw.get_item_exact(f"Machine Identity: {name}")
    if not item:
        _warn(f"identity '{name}' not found in BW — create it first")
        return False
    fields = item.get("fields") or []
    by_name = {f.get("name"): f for f in fields}
    for fld_name, val, hidden in [
        ("private_key", private_key.strip() + "\n", True),
        ("public_key",  public_key.strip()  + "\n", False),
    ]:
        f_type = 1 if hidden else 0
        if fld_name in by_name:
            by_name[fld_name]["value"] = val
            by_name[fld_name]["type"]  = f_type
        else:
            fields.append({"name": fld_name, "value": val, "type": f_type})
    item["fields"] = fields
    return bw.encode_and_edit(item["id"], item)


def import_ssh_key_files(name: str, private_path: Path | str, public_path: Path | str) -> bool:
    """Read an OpenSSH keypair from disk and import via import_ssh_key_text."""
    p_priv = Path(private_path)
    p_pub  = Path(public_path)
    if not p_priv.is_file():
        _warn(f"private key not found: {p_priv}")
        return False
    if not p_pub.is_file():
        _warn(f"public key not found: {p_pub}")
        return False
    return import_ssh_key_text(name, p_priv.read_text(), p_pub.read_text())


# ── Generic identity edit ───────────────────────────────────────────────────

def update_identity(
    name: str,
    *,
    git_name: str | None = None,
    git_email: str | None = None,
    is_default: bool | None = None,
    applies_to: list[dict] | None = None,
    ssh_key_basename: str | None = None,
) -> bool:
    """In-place update of an existing Machine Identity item. Only fields
    passed (non-None) are changed. SSH key fields are left alone."""
    cur = read_identity(name)
    if cur is None:
        _warn(f"identity '{name}' not found — use upsert_identity to create")
        return False
    return upsert_identity(
        name,
        git_name        = git_name        if git_name        is not None else cur["git_name"],
        git_email       = git_email       if git_email       is not None else cur["git_email"],
        ssh_key_basename= ssh_key_basename if ssh_key_basename is not None else cur["ssh_key_basename"],
        is_default      = is_default      if is_default      is not None else cur["default"],
        applies_to      = applies_to      if applies_to      is not None else cur["applies_to"],
        private_key     = cur["private_key"],
        public_key      = cur["public_key"],
    )


def migrate_from_toml(toml_path: Path | str, ssh_from: str | None = None) -> bool:
    """Read an identity TOML file and upsert as a Machine Identity in BW.
    If ssh_from is given (or the TOML has a bw_ssh_item field), copy SSH
    key fields from that existing BW item.
    """
    p = Path(toml_path)
    with p.open("rb") as f:
        data = tomllib.load(f)
    name = data.get("name") or p.stem
    src = ssh_from or data.get("bw_ssh_item") or ""
    target_name = f"Machine Identity: {name}"
    priv, pub = "", ""
    if src and src != target_name:
        keys = get_ssh_from_item(src)
        if keys:
            priv, pub = keys
            _log(f"Pulling SSH key from existing BW item: {src}")
        else:
            _warn(f"  no private/public_key on '{src}' — identity will be created without SSH key fields")

    return upsert_identity(
        name,
        git_name=data.get("git_name", ""),
        git_email=data.get("git_email", ""),
        ssh_key_basename=data.get("ssh_key_basename"),
        is_default=bool(data.get("default")),
        applies_to=data.get("applies_to") or [],
        private_key=priv,
        public_key=pub,
    )
