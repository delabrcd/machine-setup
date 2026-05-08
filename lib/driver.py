#!/usr/bin/env python3
"""Plan resolver + component runner.

Replaces lib/driver.sh. Plans are built via lib/config.py's existing
in-process functions (no shelling out to itself). Components still run as
shell scripts (linux.sh / windows.ps1) — they're inherently OS-specific
package-manager calls — so we subprocess them with the right env vars.
"""
from __future__ import annotations
import json, os, shlex, subprocess, sys
from pathlib import Path
from typing import Optional

# Importable as a module from main.py
sys.path.insert(0, str(Path(__file__).parent))
import config  # noqa: E402


def _log(msg: str) -> None:
    print(f"==> {msg}", file=sys.stderr, flush=True)

def _warn(msg: str) -> None:
    print(f"WARN: {msg}", file=sys.stderr, flush=True)

def _step(msg: str) -> None:
    print(f"\n--- {msg} ---", file=sys.stderr, flush=True)


# ── Plan ────────────────────────────────────────────────────────────────────

def build_plan(
    identities: list[str],
    extra_components: list[str],
    identity_overrides: dict,
    component_config: dict,
    os_tag: str | None = None,
) -> dict:
    """Build the resolved plan from per-machine inputs. Mirrors cmd_plan in
    config.py but returns a dict directly (no subprocess hop)."""
    os_tag = os_tag or config.detect_os_tag()
    required = config._required_components(identities, os_tag)

    seen: set[str] = set()
    explicit: list[str] = []
    for c in required + extra_components:
        if c not in seen:
            explicit.append(c)
            seen.add(c)

    profile = {
        "name": "_machine",
        "components": explicit,
        "identities": identities,
        "component_config": component_config,
    }
    components = config.resolve_components(profile, os_tag)

    loaded_idents: list[dict] = []
    for n in identities:
        try:
            loaded_idents.append(config.load_identity(n))
        except FileNotFoundError:
            _warn(f"identity '{n}' not found in registry or TOML — skipping")

    for ident in loaded_idents:
        raw = identity_overrides.get(ident["name"])
        if raw:
            config._apply_identity_overrides(ident, config._convert_machine_overrides(raw))

    kind = "linux" if os_tag.startswith("linux") else os_tag
    required_set = set(required)
    plan_components: list[dict] = []
    for m in components:
        script = config.component_script_path(m["name"], kind)
        plan_components.append({
            "name":         m["name"],
            "description":  m.get("description", ""),
            "per_identity": m["per_identity"],
            "script":       str(script) if script else None,
            "config":       component_config.get(m["name"], {}),
            "required":     m["name"] in required_set,
        })

    return {
        "os_tag":     os_tag,
        "components": plan_components,
        "identities": loaded_idents,
    }


# ── Component execution ─────────────────────────────────────────────────────

def _identity_env(ident: dict) -> dict:
    """Build IDENT_* env vars for a per-identity component."""
    return {
        "IDENT_NAME":              ident["name"],
        "IDENT_GIT_NAME":          ident.get("git_name", ""),
        "IDENT_GIT_EMAIL":         ident.get("git_email", ""),
        "IDENT_BW_SSH_ITEM":       ident.get("bw_ssh_item", ""),
        "IDENT_SSH_KEY_BASENAME":  ident.get("ssh_key_basename", f"id_ed25519_{ident['name']}"),
        "IDENT_DEFAULT":           "1" if ident.get("default") else "0",
        "IDENT_APPLIES_TO_JSON":   json.dumps(ident.get("applies_to", [])),
    }


def _run_script(script_path: str, extra_env: dict | None = None) -> int:
    """Run a component script. Picks the interpreter by extension."""
    extra_env = extra_env or {}
    env = {**os.environ, **extra_env}

    if script_path.endswith(".ps1"):
        from shutil import which
        ps = which("pwsh") or which("powershell")
        if not ps:
            _warn(f"no pwsh/powershell found to run {script_path}")
            return 1
        cmd = [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script_path]
    else:
        # Source lib/common.sh in the same shell so component scripts can use
        # `log`, `warn`, `step`, ensure_path, BW helpers, etc. without each
        # having to add boilerplate at the top.
        common = Path(env.get("MACHINE_SETUP_DIR", "")) / "lib" / "common.sh"
        cmd = [
            "bash", "-c",
            f". {shlex.quote(str(common))}; . {shlex.quote(script_path)}"
        ]

    return subprocess.call(cmd, env=env)


def run_plan(plan: dict, machine_setup_dir: Path) -> list[str]:
    """Run every component in plan order. Returns list of failed component
    names (empty = full success)."""
    failed: list[str] = []
    # Make machine-setup dir + identity registry visible to component scripts.
    # PLAN_JSON exposes the full resolved plan; bw-unlock-shell reads it to
    # enumerate every identity's BW SSH item.
    base_env = {
        "MACHINE_SETUP_DIR": str(machine_setup_dir),
        "PLAN_JSON":         json.dumps(plan),
    }
    if "MACHINE_SETUP_IDENTITY_REGISTRY" in os.environ:
        base_env["MACHINE_SETUP_IDENTITY_REGISTRY"] = os.environ["MACHINE_SETUP_IDENTITY_REGISTRY"]

    for comp in plan["components"]:
        name = comp["name"]
        _step(f"Component: {name}")
        if not comp["script"]:
            _warn(f"no script for '{name}' on this OS — skipping")
            continue

        # Pass per-component config as JSON
        env = {**base_env, "COMPONENT_CONFIG_JSON": json.dumps(comp.get("config") or {})}

        if comp["per_identity"]:
            if not plan["identities"]:
                _warn(f"component '{name}' is per-identity but no identities chosen — skipping")
                continue
            for ident in plan["identities"]:
                _log(f"-> identity: {ident['name']}")
                env_with_ident = {**env, **_identity_env(ident)}
                rc = _run_script(comp["script"], env_with_ident)
                if rc != 0:
                    failed.append(f"{name} [{ident['name']}]")
                    _warn(f"component '{name}' failed for identity '{ident['name']}' (exit {rc})")
        else:
            rc = _run_script(comp["script"], env)
            if rc != 0:
                failed.append(name)
                _warn(f"component '{name}' failed (exit {rc})")

    return failed


def print_summary(failed: list[str]) -> None:
    print("", file=sys.stderr)
    print("==============================", file=sys.stderr)
    if not failed:
        print("Bootstrap complete!", file=sys.stderr)
    else:
        print("Bootstrap finished with errors.", file=sys.stderr)
        print("Re-run after fixing:", file=sys.stderr)
        for f in failed:
            print(f"  - {f}", file=sys.stderr)
    print("==============================", file=sys.stderr)
