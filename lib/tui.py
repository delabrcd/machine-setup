#!/usr/bin/env python3
"""Fancy TUI for the bootstrap pickers.

Uses `questionary` (arrow-key navigation, checkboxes, search). Installed
on demand into ~/.cache/machine-setup/tui-deps/ via `pip install --target`
— no system-Python pollution. Delete the cache dir to remove cleanly.

If pip / questionary can't be made available (offline, locked-down
images), each command falls back to plain stdin prompts that work in any
TTY. Stdin is auto-redirected from /dev/tty when invoked through
`curl | bash` (the script-on-stdin pattern that breaks naive reads).

Subcommands:

    pick-identities  --available <json> --selected <csv>
    pick-auth        --pairs <json>     --current <json>
    pick-components  --required <csv>   --available <json>  --selected <csv>
    prompt-component-config  --components <csv>  --current <json>
    wizard-create-identity  (no args; emits JSON to stdout)

Each emits its result on stdout (CSV or JSON depending on the command);
status messages go to stderr so they don't pollute the captured value.
"""
from __future__ import annotations
import argparse, json, os, subprocess, sys
from pathlib import Path

CACHE_DIR = Path(os.environ.get("XDG_CACHE_HOME") or (Path.home() / ".cache")) / "machine-setup" / "tui-deps"
QUESTIONARY_PIN = "questionary>=2.0,<3.0"


def _log(msg: str) -> None:
    print(msg, file=sys.stderr, flush=True)


def _ensure_tty_stdin() -> None:
    """Redirect stdin from /dev/tty when our own stdin isn't a terminal —
    happens when bash launched us through `curl | bash` etc. questionary
    needs a real terminal for cursor positioning + key reading.
    """
    if sys.stdin.isatty():
        return
    try:
        sys.stdin = open("/dev/tty", "r")
    except OSError:
        pass


def _ensure_questionary():
    """Return the questionary module or None if it can't be loaded."""
    try:
        import questionary  # noqa: F401
        return questionary
    except ImportError:
        pass

    # Add cache dir to sys.path before retrying — handles previously-installed
    if CACHE_DIR.exists():
        sys.path.insert(0, str(CACHE_DIR))
        try:
            import questionary
            return questionary
        except ImportError:
            pass

    # Try to install via pip --target. Cache survives across runs; user can
    # `rm -rf ~/.cache/machine-setup` to wipe.
    CACHE_DIR.mkdir(parents=True, exist_ok=True)
    _log(f"==> Installing TUI dependencies into {CACHE_DIR} (one-time, ~150KB)...")
    try:
        subprocess.check_call(
            [sys.executable, "-m", "pip", "install", "--quiet",
             "--target", str(CACHE_DIR), QUESTIONARY_PIN],
            stderr=subprocess.STDOUT,
        )
    except (subprocess.CalledProcessError, FileNotFoundError) as e:
        _log(f"  pip install failed ({e}); falling back to plain prompts.")
        return None

    sys.path.insert(0, str(CACHE_DIR))
    try:
        import questionary
        return questionary
    except ImportError:
        return None


# ── Plain-text fallback ─────────────────────────────────────────────────────

def _read_tty(prompt: str) -> str:
    """Read a line from /dev/tty (or stdin if it's already a terminal)."""
    if sys.stdin.isatty():
        sys.stderr.write(prompt)
        sys.stderr.flush()
        return input()
    try:
        with open("/dev/tty", "r") as tty:
            sys.stderr.write(prompt)
            sys.stderr.flush()
            return tty.readline().rstrip("\n")
    except OSError:
        sys.exit("ERROR: no /dev/tty available for interactive prompt")


def _fallback_checkbox(title: str, choices: list[dict]) -> list[str]:
    """Numbered toggle prompt. choices: [{value, label, checked}]."""
    sel = [c.get("checked", False) for c in choices]
    while True:
        sys.stderr.write("\n" + title + "\n")
        sys.stderr.write("Toggle by number (e.g. '1 3 5'), ENTER to confirm.\n\n")
        for i, c in enumerate(choices, 1):
            mark = "[x]" if sel[i - 1] else "[ ]"
            sys.stderr.write(f"  {i:2d}) {mark} {c['label']}\n")
        line = _read_tty("\n> ")
        if not line.strip():
            break
        for tok in line.split():
            if tok.isdigit():
                n = int(tok)
                if 1 <= n <= len(choices):
                    sel[n - 1] = not sel[n - 1]
    return [c["value"] for c, on in zip(choices, sel) if on]


def _fallback_select(title: str, choices: list[dict], default: str | None = None) -> str:
    """Numbered single-select. choices: [{value, label}]."""
    sys.stderr.write("\n" + title + "\n\n")
    for i, c in enumerate(choices, 1):
        marker = "*" if c["value"] == default else " "
        sys.stderr.write(f"  {i:2d}){marker} {c['label']}\n")
    while True:
        line = _read_tty(f"\nPick [1-{len(choices)}] (ENTER for *): ").strip()
        if not line and default is not None:
            return default
        if line.isdigit():
            n = int(line)
            if 1 <= n <= len(choices):
                return choices[n - 1]["value"]
        sys.stderr.write("  invalid choice\n")


# ── Subcommands ─────────────────────────────────────────────────────────────

def cmd_pick_identities(args):
    _ensure_tty_stdin()
    available = json.loads(args.available)
    pre_selected = set(filter(None, (args.selected or "").split(",")))

    # Choices: [+] entry first, then identities
    NEW = "__create_new_identity__"
    items = [{
        "value": NEW,
        "label": "[+] Create a new identity in Bitwarden...",
        "checked": False,
    }]
    for ident in available:
        src = ident.get("source", "")
        gn  = ident.get("git_name", "")
        ge  = ident.get("git_email", "")
        suffix = f"{gn} <{ge}>" if ge else "(no email)"
        items.append({
            "value": ident["name"],
            "label": f"{ident['name']:<15} {suffix}  [{src}]",
            "checked": ident["name"] in pre_selected,
        })

    q = _ensure_questionary()
    if q:
        result = q.checkbox(
            "Pick identities to install on this machine",
            choices=[q.Choice(title=i["label"], value=i["value"], checked=i["checked"]) for i in items],
            instruction="(space to toggle, enter to confirm)",
        ).ask()
        if result is None:
            sys.exit(130)
    else:
        result = _fallback_checkbox("Identities:", items)

    print(",".join(result))


def cmd_pick_auth(args):
    """For each (identity, host) pair, ask which credential helper to use.
    args.pairs: JSON list of {identity, host, current_helper}
    args.current: JSON {identity: {host: {field: value}}} of existing overrides
    """
    _ensure_tty_stdin()
    pairs = json.loads(args.pairs)
    current = json.loads(args.current or "{}")
    q = _ensure_questionary()

    helpers = [
        {"value": "ssh",       "label": "ssh        — SSH-only auth (recommended for personal hosts)"},
        {"value": "gcm",       "label": "gcm        — Git Credential Manager (HTTPS via OAuth, needed for SSO)"},
        {"value": "bitwarden", "label": "bitwarden  — username/api-token from a BW item (Linux only)"},
        {"value": "none",      "label": "none       — no helper (clears any existing one)"},
    ]

    out = dict(current)
    for p in pairs:
        ident, host, default = p["identity"], p["host"], p.get("current_helper") or "ssh"
        title = f"Identity '{ident}' on {host} — credential helper"
        if q:
            choice = q.select(
                title,
                choices=[q.Choice(title=h["label"], value=h["value"]) for h in helpers],
                default=default,
                instruction="(arrow keys to choose, enter to confirm)",
            ).ask()
            if choice is None:
                sys.exit(130)
        else:
            choice = _fallback_select(title, helpers, default=default)
        out.setdefault(ident, {}).setdefault(host, {})["credential_helper"] = choice

    print(json.dumps(out))


def cmd_pick_components(args):
    _ensure_tty_stdin()
    required = [c for c in (args.required or "").split(",") if c]
    available = json.loads(args.available)
    pre_selected = set(filter(None, (args.selected or "").split(",")))

    # Display required as a non-interactive header
    if required:
        _log("\n--- Required components (auto-installed) ---")
        for c in required:
            _log(f"  [R] {c}")

    # Filter out required from choices (don't show as togglable)
    optional = [c for c in available if c["name"] not in set(required)]
    if not optional:
        print("")
        return

    items = []
    for c in optional:
        items.append({
            "value": c["name"],
            "label": f"{c['name']:<22} {c.get('description','')[:55]}",
            "checked": c["name"] in pre_selected,
        })

    q = _ensure_questionary()
    if q:
        result = q.checkbox(
            "Optional components",
            choices=[q.Choice(title=i["label"], value=i["value"], checked=i["checked"]) for i in items],
            instruction="(space to toggle, enter to confirm)",
        ).ask()
        if result is None:
            sys.exit(130)
    else:
        result = _fallback_checkbox("Optional components:", items)

    print(",".join(result))


def cmd_prompt_component_config(args):
    """Walks selected components that need config, prompts for missing fields."""
    _ensure_tty_stdin()
    selected = set(filter(None, (args.components or "").split(",")))
    current = json.loads(args.current or "{}")
    q = _ensure_questionary()

    # The list of components that need config + their fields. Each field has
    # a label, an optional default, and a description.
    schema = {
        "chezmoi": [
            ("repo", "dotfiles repo URL (e.g. https://github.com/<you>/dotfiles.git)", None),
        ],
        "dev-utilities": [
            ("repo", "git URL of repo to clone", None),
            ("dest", "destination path (default: ~/.local/share/dev-utilities)", "~/.local/share/dev-utilities"),
        ],
        "bitbucket-mcp": [
            ("path", "MCP source dir (default: ~/.local/share/dev-utilities/bitbucket-mcp)",
                "~/.local/share/dev-utilities/bitbucket-mcp"),
        ],
        "wsl-bootstrap": [
            ("distro", "WSL distro name (default: Ubuntu)", "Ubuntu"),
        ],
    }

    def _ask(title: str, default: str | None) -> str:
        if q:
            r = q.text(title, default=default or "").ask()
            if r is None:
                sys.exit(130)
            return r.strip()
        return _read_tty(title + ("" if not default else f" [{default}]") + ": ").strip() or (default or "")

    for comp, fields in schema.items():
        if comp not in selected:
            continue
        comp_cfg = current.setdefault(comp, {})
        _log(f"\n[{comp}]")
        for field, label, default in fields:
            existing = comp_cfg.get(field)
            if existing:
                _log(f"  {field}: {existing}  (kept)")
                continue
            val = _ask(f"  {field} — {label}", default)
            if val:
                comp_cfg[field] = val
            elif default:
                comp_cfg[field] = default

    print(json.dumps(current))


def cmd_wizard_create_identity(args):
    """Interactive identity creation. Emits JSON ready for seed-bw-identity.
    Output keys: name, git_name, git_email, default ('true'|'false'),
                 host, credential_helper, register_url, register_label
    Caller still needs to actually create the BW item (we just gather inputs).
    """
    _ensure_tty_stdin()
    q = _ensure_questionary()

    def _text(title, default=None, validate=None):
        if q:
            r = q.text(title, default=default or "", validate=validate).ask()
            if r is None:
                sys.exit(130)
            return r.strip()
        v = _read_tty(title + (f" [{default}]" if default else "") + ": ").strip()
        return v or (default or "")

    def _confirm(title, default=False):
        if q:
            r = q.confirm(title, default=default).ask()
            if r is None:
                sys.exit(130)
            return r
        v = _read_tty(title + (" [Y/n]: " if default else " [y/N]: ")).strip().lower()
        if not v:
            return default
        return v.startswith("y")

    def _select(title, choices, default=None):
        if q:
            r = q.select(title, choices=[q.Choice(title=c["label"], value=c["value"]) for c in choices],
                         default=default).ask()
            if r is None:
                sys.exit(130)
            return r
        return _fallback_select(title, choices, default=default)

    def _name_validate(s):
        import re
        return True if re.fullmatch(r"[A-Za-z0-9_-]+", s) else "letters/digits/-/_ only"

    name      = _text("Identity name (e.g. personal)", validate=_name_validate)
    git_name  = _text("git user.name")
    git_email = _text("git user.email")
    is_default = _confirm("Make this the default identity (global git config)?", default=True)
    host      = _text("Primary host for this identity (e.g. github.com)")

    helpers = [
        {"value": "ssh",       "label": "ssh        — SSH-only (recommended)"},
        {"value": "gcm",       "label": "gcm        — Git Credential Manager / HTTPS"},
        {"value": "bitwarden", "label": "bitwarden  — username/api-token from a BW item"},
        {"value": "none",      "label": "none       — no helper"},
    ]
    helper = _select(f"credential_helper for {host}", helpers, default="ssh") if host else "ssh"

    out = {
        "name": name,
        "git_name": git_name,
        "git_email": git_email,
        "default": "true" if is_default else "false",
        "host": host,
        "credential_helper": helper,
    }
    print(json.dumps(out))


def main():
    p = argparse.ArgumentParser()
    sub = p.add_subparsers(dest="cmd", required=True)

    p1 = sub.add_parser("pick-identities")
    p1.add_argument("--available", required=True, help="JSON list of available identities")
    p1.add_argument("--selected",  default="",     help="CSV of pre-selected names")
    p1.set_defaults(func=cmd_pick_identities)

    p2 = sub.add_parser("pick-auth")
    p2.add_argument("--pairs",   required=True, help="JSON list of {identity,host,current_helper}")
    p2.add_argument("--current", default="{}",  help="JSON of existing overrides")
    p2.set_defaults(func=cmd_pick_auth)

    p3 = sub.add_parser("pick-components")
    p3.add_argument("--required",  default="",     help="CSV of required component names (info only)")
    p3.add_argument("--available", required=True, help="JSON list of all available components for this OS")
    p3.add_argument("--selected",  default="",     help="CSV of pre-selected optional names")
    p3.set_defaults(func=cmd_pick_components)

    p4 = sub.add_parser("prompt-component-config")
    p4.add_argument("--components", default="",   help="CSV of components in the resolved plan")
    p4.add_argument("--current",    default="{}", help="JSON of existing component_config")
    p4.set_defaults(func=cmd_prompt_component_config)

    p5 = sub.add_parser("wizard-create-identity")
    p5.set_defaults(func=cmd_wizard_create_identity)

    args = p.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
