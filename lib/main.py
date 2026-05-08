#!/usr/bin/env python3
"""Bootstrap orchestrator. Single Python entrypoint replacing what used to
be split across bootstrap.sh, lib/ui.sh, lib/driver.sh, lib/bw-session.sh.

Components themselves still ship as shell scripts (linux.sh / windows.ps1)
because they're inherently OS-specific package-manager calls; we run them
via subprocess from here.

Entrypoints (invoked from bootstrap.sh / bootstrap.ps1):
    python3 lib/main.py [--reconfigure] [--quiet]
"""
from __future__ import annotations
import argparse, json, os, shutil, signal, subprocess, sys, tempfile
from pathlib import Path

LIB_DIR = Path(__file__).resolve().parent
ROOT    = LIB_DIR.parent
sys.path.insert(0, str(LIB_DIR))

import bw            # noqa: E402
import config        # noqa: E402
import driver        # noqa: E402
import machine_config as mc  # noqa: E402
import identity_ops  # noqa: E402
import tui           # noqa: E402

# Optional Textual import — handled lazily in run_pickers()
_app_module = None


# ── Logging helpers ─────────────────────────────────────────────────────────

def log(msg: str) -> None:
    print(f"==> {msg}", file=sys.stderr, flush=True)

def warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr, flush=True)

def step(msg: str) -> None:
    print(f"\n--- {msg} ---", file=sys.stderr, flush=True)

def die(msg: str, code: int = 1) -> None:
    print(f"ERROR: {msg}", file=sys.stderr, flush=True)
    sys.exit(code)


# ── Self-update (called from bootstrap.sh re-exec) ──────────────────────────

def maybe_self_update() -> None:
    """Pull the latest from origin and re-exec ourselves. The bash stub also
    does this; this is a backstop for direct `python3 lib/main.py` calls.
    """
    if os.environ.get("_BOOTSTRAP_UPDATED"):
        return
    if not (ROOT / ".git").exists():
        return
    log("Updating machine-setup...")
    subprocess.call(["git", "-C", str(ROOT), "fetch", "origin"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    subprocess.call(["git", "-C", str(ROOT), "reset", "--hard", "origin/HEAD"], stdout=subprocess.DEVNULL, stderr=subprocess.DEVNULL)
    os.environ["_BOOTSTRAP_UPDATED"] = "1"
    os.execv(sys.executable, [sys.executable, str(LIB_DIR / "main.py"), *sys.argv[1:]])


# ── Migration: legacy machine.toml (profile=...) ────────────────────────────

def migrate_legacy(state: dict) -> dict:
    """If state has a `_legacy.profile` field and that profile exists on disk,
    copy its component_config + identity_overrides into the new schema."""
    legacy = state.get("_legacy") or {}
    profile_name = legacy.get("profile")
    if not profile_name:
        return state

    log(f"Detected legacy machine.toml (profile={profile_name}) — migrating into new schema...")
    profile_path = None
    for base in (ROOT / "local/profiles", ROOT / "profiles"):
        candidate = base / f"{profile_name}.toml"
        if candidate.exists():
            profile_path = candidate
            break
    if not profile_path:
        warn(f"  Profile '{profile_name}' not found on disk — nothing to migrate from.")
        return state

    import tomllib
    with profile_path.open("rb") as f:
        profile = tomllib.load(f)

    comp_cfg = state.get("component_config") or {}
    for comp, cfg in (profile.get("component_config") or {}).items():
        if comp not in comp_cfg:
            comp_cfg[comp] = cfg
        else:
            for k, v in (cfg or {}).items():
                comp_cfg[comp].setdefault(k, v)

    ident_over = state.get("identity_overrides") or {}
    for ident_name, ov in (profile.get("identity_overrides") or {}).items():
        target = ident_over.setdefault(ident_name, {})
        for at in (ov.get("applies_to") or []):
            host = at.get("host")
            if not host:
                continue
            sub = target.setdefault(host, {})
            for k, v in at.items():
                if k == "host":
                    continue
                sub.setdefault(k, v)
        for k, v in ov.items():
            if k == "applies_to":
                continue
            if not isinstance(v, dict):
                target.setdefault(k, v)

    extra = state.get("extra_components") or []
    legacy_components = legacy.get("components") or profile.get("components") or []
    for c in legacy_components:
        if c not in extra:
            extra.append(c)

    state["component_config"]   = comp_cfg
    state["identity_overrides"] = ident_over
    state["extra_components"]   = extra
    state.pop("_legacy", None)
    log("  Migrated component_config + identity_overrides from profile.")
    return state


# ── Pickers (subprocess to lib/tui.py) ──────────────────────────────────────

def _run_tui(*subcmd_args: str) -> str:
    """Run lib/tui.py with the given args. The result is written to a temp
    file (--output) so the subprocess can keep stdout/stderr connected to
    the user's terminal — questionary needs that to render its TUI.
    Returns the file contents (stripped).
    """
    out_path = Path(tempfile.mktemp(suffix=".tui-out"))
    cmd = [sys.executable, str(LIB_DIR / "tui.py"), *subcmd_args, "--output", str(out_path)]
    try:
        proc = subprocess.run(cmd)  # no capture_output — user sees the UI
        if proc.returncode == 130:
            die("Aborted by user.", 130)
        if proc.returncode != 0:
            die(f"TUI step failed (exit {proc.returncode})", proc.returncode)
        if not out_path.exists():
            return ""
        return out_path.read_text().rstrip("\n")
    finally:
        out_path.unlink(missing_ok=True)


_NEW_IDENT_TAG = "__create_new_identity__"


def pick_identities(state: dict, force: bool, quiet: bool) -> None:
    if os.environ.get("MACHINE_SETUP_IDENTITIES"):
        state["identities"] = [n for n in os.environ["MACHINE_SETUP_IDENTITIES"].split(",") if n]
        log(f"Using identities from MACHINE_SETUP_IDENTITIES: {','.join(state['identities'])}")
        return
    if quiet:
        log("Quiet mode: keeping saved identities.")
        return

    # Always show the picker — saved values pre-checked. User confirms with ENTER
    # to keep, or toggles to change. force is now redundant but kept for symmetry.
    _ = force
    while True:
        # available list = identities discovered + any TOML fallbacks. We use
        # config.list_known_identities which already merges them.
        os.environ["MACHINE_SETUP_IDENTITY_REGISTRY"] = str(_REGISTRY_FILE)
        available = config.list_known_identities()

        picked_csv = _run_tui(
            "pick-identities",
            "--available", json.dumps(available),
            "--selected",  ",".join(state.get("identities") or []),
        )
        picked = [n for n in picked_csv.split(",") if n]
        if _NEW_IDENT_TAG in picked:
            picked = [n for n in picked if n != _NEW_IDENT_TAG]
            state["identities"] = picked
            create_identity_wizard()
            continue
        state["identities"] = picked
        break


def create_identity_wizard() -> None:
    """Drop the user into the wizard, then refresh the registry in place."""
    payload = _run_tui("wizard-create-identity")
    inputs = json.loads(payload)
    ok = identity_ops.create_identity_interactive(
        name=inputs["name"],
        git_name=inputs["git_name"],
        git_email=inputs["git_email"],
        is_default=(inputs.get("default") == "true"),
        host=inputs.get("host", ""),
        credential_helper=inputs.get("credential_helper", "ssh"),
    )
    if not ok:
        warn("Identity creation failed")
        return
    # Refresh the registry file so the picker re-shows with the new entry
    bw.write_identity_registry(_REGISTRY_FILE)


def pick_auth(state: dict, quiet: bool) -> None:
    if quiet:
        log("Quiet mode: keeping existing auth settings.")
        return
    if not state.get("identities"):
        return

    pairs: list[dict] = []
    existing = state.get("identity_overrides") or {}
    for name in state["identities"]:
        try:
            ident = config.load_identity(name)
        except FileNotFoundError:
            warn(f"identity '{name}' not in registry/TOML — skipping in auth picker")
            continue
        for at in (ident.get("applies_to") or []):
            host = at.get("host")
            if not host:
                continue
            current = (
                existing.get(name, {}).get(host, {}).get("credential_helper")
                or at.get("credential_helper") or "ssh"
            )
            pairs.append({"identity": name, "host": host, "current_helper": current})
    if not pairs:
        return

    new_overrides_json = _run_tui(
        "pick-auth",
        "--pairs",   json.dumps(pairs),
        "--current", json.dumps(existing),
    )
    state["identity_overrides"] = json.loads(new_overrides_json)


def pick_components(state: dict, os_tag: str, force: bool, quiet: bool) -> None:
    if os.environ.get("MACHINE_SETUP_COMPONENTS"):
        state["extra_components"] = [c for c in os.environ["MACHINE_SETUP_COMPONENTS"].split(",") if c]
        log(f"Using extra components from MACHINE_SETUP_COMPONENTS")
        return
    if quiet:
        log("Quiet mode: keeping saved extra components.")
        return

    # Always show — saved values pre-checked. force kept for symmetry.
    _ = force
    required = config._required_components(state.get("identities") or [], os_tag)
    available = []
    for c in config.list_all_components():
        if os_tag not in c.get("supported", []):
            continue
        available.append(c)

    picked_csv = _run_tui(
        "pick-components",
        "--required",  ",".join(required),
        "--available", json.dumps(available),
        "--selected",  ",".join(state.get("extra_components") or []),
    )
    state["extra_components"] = [c for c in picked_csv.split(",") if c]


def prompt_component_config(state: dict, os_tag: str, quiet: bool) -> None:
    if quiet:
        return
    plan = driver.build_plan(
        identities=state.get("identities") or [],
        extra_components=state.get("extra_components") or [],
        identity_overrides=state.get("identity_overrides") or {},
        component_config=state.get("component_config") or {},
        os_tag=os_tag,
    )
    plan_components = ",".join(c["name"] for c in plan["components"])
    new_cfg_json = _run_tui(
        "prompt-component-config",
        "--components", plan_components,
        "--current",    json.dumps(state.get("component_config") or {}),
    )
    state["component_config"] = json.loads(new_cfg_json)


# ── Textual fullscreen pickers ──────────────────────────────────────────────

def run_textual_pickers(state: dict, os_tag: str, registry_file: Path) -> tuple[bool, list[str] | None]:
    """Drive the entire interactive phase + plan execution via the Textual
    app. Returns (handled_in_textual, failed_components_or_None).

    handled_in_textual = True when the Textual flow ran end-to-end (incl. plan).
                         The caller skips its own plan run.
    handled_in_textual = False when Textual unavailable; caller falls back to
                         questionary pickers + plain-terminal plan run.
    """
    if not sys.stdin.isatty():
        return (False, None)
    if tui.ensure_textual() is None:
        return (False, None)
    try:
        import app as _app  # noqa: F401  (loads from LIB_DIR via sys.path)
    except Exception as e:
        log(f"Textual app failed to import ({type(e).__name__}: {e}); falling back")
        return (False, None)

    while True:
        result = _app.run_app(
            initial_state=state,
            registry_file=registry_file,
            os_tag=os_tag,
        )
        action = (result or {}).get("action")
        if action == "abort":
            die("Aborted by user.", 130)
        if action == "create_identity":
            state.update(result.get("state") or {})
            run_create_identity_wizard()
            continue
        # done — plan has already run inside the app, summary already shown
        state.update(result.get("state") or {})
        return (True, result.get("failed") or [])


def run_create_identity_wizard() -> None:
    """Drop into questionary wizard to gather inputs, then create the BW
    item via identity_ops + refresh the registry. Used by both the Textual
    [+] flow and the questionary fallback path.
    """
    out_path = Path(tempfile.mktemp(suffix=".tui-out"))
    try:
        rc = subprocess.call([
            sys.executable, str(LIB_DIR / "tui.py"),
            "wizard-create-identity", "--output", str(out_path),
        ])
        if rc != 0 or not out_path.exists():
            warn("Identity wizard cancelled")
            return
        inputs = json.loads(out_path.read_text())
    finally:
        out_path.unlink(missing_ok=True)

    ok = identity_ops.create_identity_interactive(
        name=inputs["name"],
        git_name=inputs["git_name"],
        git_email=inputs["git_email"],
        is_default=(inputs.get("default") == "true"),
        host=inputs.get("host", ""),
        credential_helper=inputs.get("credential_helper", "ssh"),
    )
    if not ok:
        warn("Identity creation failed")
        return
    bw.write_identity_registry(_REGISTRY_FILE)


# ── Main ────────────────────────────────────────────────────────────────────

# Path to the registry file we'll populate post-BW-unlock. Set in main().
_REGISTRY_FILE: Path = Path()


def _cleanup_deprecated() -> None:
    """One-time cleanup of artifacts from removed/replaced components.

    Currently handled:
      - In-house bitbucket-mcp (replaced by aashari/mcp-server-atlassian-bitbucket
        invoked via npx). Removes the built artifacts at
        ~/.local/share/dev-utilities/bitbucket-mcp/{dist,node_modules,package-lock.json}
        so disk doesn't keep stale junk. The dev-utilities clone itself stays
        — it may contain other tooling.
    """
    if sys.platform == "win32":
        return  # Windows side never built it
    bbmcp = Path.home() / ".local" / "share" / "dev-utilities" / "bitbucket-mcp"
    targets = [bbmcp / "dist", bbmcp / "node_modules", bbmcp / "package-lock.json"]
    if not any(t.exists() for t in targets):
        return
    log("Cleaning up deprecated in-house bitbucket-mcp artifacts...")
    for t in targets:
        if not t.exists():
            continue
        try:
            if t.is_dir():
                shutil.rmtree(t, ignore_errors=True)
            else:
                t.unlink(missing_ok=True)
            log(f"  removed {t}")
        except Exception as e:
            warn(f"  failed to remove {t}: {e}")


def _ensure_local_bin_on_path() -> None:
    """Add ~/.local/bin to PATH if it exists. Many of the tools we install
    (bw, uv, claude, git-credential-manager) land there, but a non-
    interactive shell launched via curl|bash often doesn't have it on PATH.
    Without this, our `which`-based detection re-downloads tools every run.
    """
    local_bin = Path.home() / ".local" / "bin"
    if local_bin.is_dir():
        path = os.environ.get("PATH", "")
        if str(local_bin) not in path.split(os.pathsep):
            os.environ["PATH"] = str(local_bin) + os.pathsep + path


def _ensure_tty_stdin() -> None:
    """When launched via `curl | bash`, our stdin is the (closed) curl pipe.
    Redirect from /dev/tty so questionary, Textual, and bw all have a real
    terminal to read from. No-op if stdin is already a tty or /dev/tty isn't
    available (CI, non-interactive shells)."""
    if sys.stdin.isatty():
        return
    try:
        tty = open("/dev/tty", "r")
        sys.stdin = tty
        os.dup2(tty.fileno(), 0)  # make low-level fd 0 a tty too
    except OSError:
        pass


def main() -> int:
    # Ctrl+C exits cleanly with code 130 (no traceback)
    signal.signal(signal.SIGINT, lambda *_: sys.exit(130))

    _ensure_local_bin_on_path()
    _ensure_tty_stdin()
    _cleanup_deprecated()

    parser = argparse.ArgumentParser(prog="machine-setup")
    parser.add_argument("--reconfigure", "-r", action="store_true",
                        help="Re-run every picker; ignore saved selections.")
    parser.add_argument("--quiet", "-q", action="store_true",
                        help="Skip pickers; use saved/env-supplied selections.")
    args = parser.parse_args()

    maybe_self_update()

    # Detect OS + load saved state quietly — no banners, the TUI takes over
    # immediately after this.
    os_tag = config.detect_os_tag()

    config_dir = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "machine-setup"
    config_file = config_dir / "machine.toml"
    if args.reconfigure and config_file.exists():
        config_file.unlink()

    raw = subprocess.run(
        [sys.executable, str(LIB_DIR / "machine_config.py"), "load", str(config_file)],
        capture_output=True, text=True
    )
    state = json.loads(raw.stdout) if raw.stdout.strip() else {}
    state = migrate_legacy(state)

    # Make sure bw is available before launching the TUI. On a fresh machine
    # the Bitwarden CLI isn't installed yet — fetch it now so identity
    # discovery actually finds something.
    if not bw.have_bw():
        log("Bitwarden CLI not installed; fetching the official binary...")
        bw.ensure_installed()

    # Reserve a registry path; BW unlock + discovery run inside the Textual app
    # so the user sees the TUI as the very first interactive surface.
    global _REGISTRY_FILE
    bw_cache = Path(tempfile.mkdtemp(prefix="machine-setup-bw-"))
    _REGISTRY_FILE = bw_cache / "identities.json"
    _REGISTRY_FILE.write_text("{}")
    os.environ["MACHINE_SETUP_IDENTITY_REGISTRY"] = str(_REGISTRY_FILE)

    if not args.quiet:
        handled, failed = run_textual_pickers(state, os_tag, _REGISTRY_FILE)
        if handled:
            # The Textual app already ran the plan + showed the summary;
            # main.py just exits with the right code.
            return 0 if not failed else 1

    # Fallback path: BW unlock + discovery + questionary pickers in steps.
    step("OS detection")
    log(f"OS tag: {os_tag}")

    step("Bitwarden session")
    if bw.have_bw():
        bw.unlock()
    else:
        warn("bw CLI not installed yet — install will add it; re-run after.")

    step("BW discovery")
    if bw.is_unlocked():
        bw.write_identity_registry(_REGISTRY_FILE)

    step("Identity selection")
    pick_identities(state, force=args.reconfigure, quiet=args.quiet)
    step("Per-identity auth")
    pick_auth(state, quiet=args.quiet)
    step("Component selection")
    pick_components(state, os_tag, force=args.reconfigure, quiet=args.quiet)
    step("Component configuration")
    prompt_component_config(state, os_tag, quiet=args.quiet)

    # Persist all state
    config_dir.mkdir(parents=True, exist_ok=True)
    payload = json.dumps({
        "identities":         state.get("identities") or [],
        "extra_components":   state.get("extra_components") or [],
        "identity_overrides": state.get("identity_overrides") or {},
        "component_config":   state.get("component_config") or {},
    })
    proc = subprocess.run(
        [sys.executable, str(LIB_DIR / "machine_config.py"), "dump", str(config_file)],
        input=payload, text=True,
    )
    if proc.returncode != 0:
        warn("Failed to persist machine.toml")
    log(f"Saved selections to {config_file}")

    # Pre-cache sudo only when the TUI didn't already do it. (TUI sets
    # state["_sudo_cached"] when it captured + cached the password via the
    # SudoScreen.) Fallback for the questionary path or non-TTY runs.
    if (
        not state.get("_sudo_cached")
        and shutil.which("sudo")
        and hasattr(os, "geteuid")
        and os.geteuid() != 0
    ):
        step("Sudo")
        log("Caching sudo credentials...")
        rc = subprocess.call(["sudo", "-v"])
        if rc != 0:
            warn("sudo -v failed — components needing sudo may re-prompt during install")

    step("Resolve plan")
    plan = driver.build_plan(
        identities=state.get("identities") or [],
        extra_components=state.get("extra_components") or [],
        identity_overrides=state.get("identity_overrides") or {},
        component_config=state.get("component_config") or {},
        os_tag=os_tag,
    )
    log(f"Components: {' '.join(c['name'] for c in plan['components'])}")
    log(f"Identities: {' '.join(i['name'] for i in plan['identities'])}")

    failed = driver.run_plan(plan, ROOT)
    driver.print_summary(failed)
    return 0 if not failed else 1


if __name__ == "__main__":
    sys.exit(main())
