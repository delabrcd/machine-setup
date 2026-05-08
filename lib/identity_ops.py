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
