#!/usr/bin/env python3
"""Profile / identity / component config loader for machine-setup.

Schema overview
---------------
profiles/<name>.toml
    name = "personal-server"           # optional; defaults to filename
    description = "..."                # optional, shown in TUI
    components = ["packages", ...]     # required; deps resolved automatically
    identities = ["personal"]          # required; each must have an identity file
    [component_config.<component>]     # optional per-component overrides
        any.key = "..."

identities/<name>.toml
    name = "personal"                  # optional; defaults to filename
    git_name = "delabrcd"
    git_email = "..."
    bw_ssh_item = "Machine SSH Key"    # optional; omit to skip ssh-key install
    ssh_key_basename = "id_ed25519_personal"  # optional; default = "id_ed25519_<name>"
    default = true                     # exactly one identity per profile must set this
    [[applies_to]]                     # zero or more application targets
        host = "github.com"
        git_url_patterns = ["git@github.com:*/*", "https://github.com/*/*"]
        credential_helper = "gcm"      # gcm | bitwarden | ssh | none
        # for bitwarden helper:
        bw_credential_item = "..."
        bw_username_field = "username"
        bw_password_field = "api_token"
        register_url = "..."           # printed when key is freshly generated
        register_label = "..."

components/<name>/manifest.toml
    name = "claude-code"
    description = "..."
    supported = ["linux-ubuntu", "linux-fedora", "linux-arch", "windows", "wsl", "macos"]
    depends_on = ["nvm"]               # ordering only; missing deps -> error
    per_identity = false               # if true, driver invokes once per identity

Overlay
-------
For every directory above (profiles, identities, components), local/<dir>/<name>.toml
overrides repo/<dir>/<name>.toml. local/ is gitignored — that's where work configs
live so the public repo carries no employer data.
"""
from __future__ import annotations

import argparse
import json
import os
import sys
from pathlib import Path  # noqa: F401  (kept for clarity)

try:
    import tomllib  # py3.11+
except ImportError:  # pragma: no cover
    try:
        import tomli as tomllib  # type: ignore
    except ImportError:
        sys.exit("ERROR: tomllib (py3.11+) or tomli required to parse config")


REPO = Path(__file__).resolve().parent.parent
LOCAL = REPO / "local"


def _load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def _resolve(kind: str, name: str) -> Path:
    """Find <kind>/<name>.toml — local/ overrides repo root."""
    for base in (LOCAL, REPO):
        candidate = base / kind / f"{name}.toml"
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"{kind}/{name}.toml not found in local/ or repo")


def _resolve_component(name: str) -> Path:
    """components/<name>/manifest.toml — local/ overrides repo."""
    for base in (LOCAL, REPO):
        candidate = base / "components" / name / "manifest.toml"
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"components/{name}/manifest.toml not found")


def component_script_path(name: str, kind: str) -> Path | None:
    """Find the per-OS script for a component. kind: linux | windows | wsl | macos.

    local/ wins over repo. Returns None if no script exists for that OS.
    """
    filenames = {
        "linux": ["linux.sh"],
        "windows": ["windows.ps1"],
        "wsl": ["wsl.sh", "linux.sh"],  # wsl falls back to linux
        "macos": ["macos.sh", "linux.sh"],  # macos can fall back to linux
    }[kind]
    for base in (LOCAL, REPO):
        for fn in filenames:
            p = base / "components" / name / fn
            if p.exists():
                return p
    return None


def list_profiles() -> list[dict]:
    """All profiles known across local/ + repo, deduped (local wins by name)."""
    seen: dict[str, dict] = {}
    for base in (REPO, LOCAL):  # repo first so local overrides
        d = base / "profiles"
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.toml")):
            data = _load_toml(p)
            name = data.get("name") or p.stem
            seen[name] = {
                "name": name,
                "description": data.get("description", ""),
                "source": "local" if base == LOCAL else "repo",
            }
    return list(seen.values())


def load_profile(name: str) -> dict:
    path = _resolve("profiles", name)
    data = _load_toml(path)
    data.setdefault("name", name)
    data.setdefault("components", [])
    data.setdefault("identities", [])
    data.setdefault("component_config", {})
    data.setdefault("identity_overrides", {})
    return data


def _apply_identity_overrides(identity: dict, overrides: dict) -> None:
    """Merge per-host applies_to overrides into the resolved identity in place.

    Profile schema (also accepted in machine.toml later if we extend it):

        [[identity_overrides.personal.applies_to]]
        host = "github.com"
        credential_helper = "gcm"

    Lookup is by `host` — if the identity already has an applies_to entry for
    that host, override-keys are merged onto it (override wins). If no entry
    matches, the override is appended as a new applies_to entry.
    """
    if not overrides:
        return
    for over_at in overrides.get("applies_to", []) or []:
        host = over_at.get("host")
        if not host:
            continue
        merged = False
        for at in identity.get("applies_to", []):
            if at.get("host") == host:
                for k, v in over_at.items():
                    if k == "host":
                        continue
                    at[k] = v
                merged = True
                break
        if not merged:
            identity.setdefault("applies_to", []).append(dict(over_at))
    # Top-level identity-field overrides (rare but useful — e.g. force a
    # different ssh_key_basename on this profile).
    for k, v in overrides.items():
        if k == "applies_to":
            continue
        identity[k] = v


def _registry_lookup(name: str) -> dict | None:
    """If MACHINE_SETUP_IDENTITY_REGISTRY points at a JSON file, look up
    `name` in it. The registry is populated at runtime by the bootstraps
    after Bitwarden unlock (one entry per "Machine Identity: <name>" item).
    """
    path = os.environ.get("MACHINE_SETUP_IDENTITY_REGISTRY")
    if not path or not os.path.exists(path):
        return None
    try:
        with open(path) as f:
            registry = json.load(f)
    except Exception:
        return None
    return registry.get(name)


def load_identity(name: str) -> dict:
    # 1. Runtime registry (BW-discovered identities) wins. The bootstrap
    #    populates this before any per-identity component runs.
    data = _registry_lookup(name)
    if data is not None:
        data = dict(data)  # copy — don't mutate registry
        data.setdefault("name", name)
        data.setdefault("ssh_key_basename", f"id_ed25519_{data['name']}")
        data.setdefault("applies_to", [])
        return data
    # 2. local/identities/<name>.toml or identities/<name>.toml fallback
    path = _resolve("identities", name)
    data = _load_toml(path)
    data.setdefault("name", name)
    data.setdefault("ssh_key_basename", f"id_ed25519_{data['name']}")
    data.setdefault("applies_to", [])
    return data


def list_known_identities() -> list[dict]:
    """Every identity discoverable on this machine: registry entries (BW)
    + TOML files. Registry wins on name collision. Used by the picker.
    """
    out: dict[str, dict] = {}
    # TOML files first
    for base in (REPO, LOCAL):
        d = base / "identities"
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.toml")):
            data = _load_toml(p)
            name = data.get("name") or p.stem
            out[name] = {
                "name": name,
                "git_name": data.get("git_name", ""),
                "git_email": data.get("git_email", ""),
                "default": bool(data.get("default")),
                "source": "local-toml" if base == LOCAL else "repo-toml",
            }
    # BW registry overrides
    path = os.environ.get("MACHINE_SETUP_IDENTITY_REGISTRY")
    if path and os.path.exists(path):
        try:
            with open(path) as f:
                registry = json.load(f)
            for name, data in registry.items():
                out[name] = {
                    "name": name,
                    "git_name": data.get("git_name", ""),
                    "git_email": data.get("git_email", ""),
                    "default": bool(data.get("default")),
                    "source": "bitwarden",
                }
        except Exception:
            pass
    return list(out.values())


def load_component_manifest(name: str) -> dict:
    path = _resolve_component(name)
    data = _load_toml(path)
    data.setdefault("name", name)
    data.setdefault("supported", [])
    data.setdefault("depends_on", [])
    data.setdefault("per_identity", False)
    return data


def resolve_components(profile: dict, os_tag: str, override: list[str] | None = None) -> list[dict]:
    """Topo-sort components, pulling in transitive deps.

    os_tag is one of: linux-ubuntu, linux-fedora, linux-arch, windows, wsl, macos.
    Components whose `supported` list omits os_tag are skipped silently — that's
    how a single profile works on multiple OSes (e.g. uv on Linux only).

    If `override` is given, it replaces the profile's components list entirely
    (deps are still pulled in transitively). This is the picker's escape hatch.
    """
    explicit = list(override if override is not None else profile["components"])
    visited: set[str] = set()
    order: list[str] = []

    def visit(comp_name: str, stack: tuple[str, ...] = ()):
        if comp_name in visited:
            return
        if comp_name in stack:
            raise ValueError(f"component dep cycle: {' -> '.join(stack + (comp_name,))}")
        manifest = load_component_manifest(comp_name)
        for dep in manifest["depends_on"]:
            visit(dep, stack + (comp_name,))
        visited.add(comp_name)
        order.append(comp_name)

    for c in explicit:
        visit(c)

    out = []
    for c in order:
        m = load_component_manifest(c)
        if os_tag not in m["supported"]:
            continue
        out.append(m)
    return out


def list_all_components() -> list[dict]:
    """Every component known across local/ + repo, deduped by name (local wins)."""
    seen: dict[str, dict] = {}
    for base in (REPO, LOCAL):
        d = base / "components"
        if not d.is_dir():
            continue
        for entry in sorted(d.iterdir()):
            manifest = entry / "manifest.toml"
            if not manifest.exists():
                continue
            data = _load_toml(manifest)
            name = data.get("name") or entry.name
            seen[name] = {
                "name": name,
                "description": data.get("description", ""),
                "supported": data.get("supported", []),
                "depends_on": data.get("depends_on", []),
                "per_identity": data.get("per_identity", False),
                "source": "local" if base == LOCAL else "repo",
            }
    return list(seen.values())


def detect_os_tag() -> str:
    """Return the OS tag string used by component manifests."""
    if sys.platform == "win32":
        return "windows"
    if sys.platform == "darwin":
        return "macos"
    # Linux: check WSL, else parse /etc/os-release
    try:
        with open("/proc/version") as f:
            if any(s in f.read().lower() for s in ("microsoft", "wsl")):
                return "wsl"
    except OSError:
        pass
    try:
        with open("/etc/os-release") as f:
            kv = dict(
                line.strip().split("=", 1)
                for line in f
                if "=" in line and not line.startswith("#")
            )
    except OSError:
        return "linux-unknown"
    distro_id = kv.get("ID", "").strip('"')
    family = {
        "ubuntu": "linux-ubuntu", "debian": "linux-ubuntu", "linuxmint": "linux-ubuntu",
        "fedora": "linux-fedora", "rhel": "linux-fedora", "centos": "linux-fedora",
        "rocky": "linux-fedora", "almalinux": "linux-fedora",
        "arch": "linux-arch", "manjaro": "linux-arch", "endeavouros": "linux-arch",
    }
    return family.get(distro_id, f"linux-{distro_id or 'unknown'}")


def cmd_os_tag(_):
    print(detect_os_tag())


def cmd_list_profiles(_):
    for p in list_profiles():
        print(json.dumps(p))


def cmd_resolve(args):
    profile = load_profile(args.profile)
    os_tag = args.os_tag or detect_os_tag()
    override = None
    if args.components is not None:
        # `--components ""` means "empty list", `--components a,b,c` is the list.
        override = [c.strip() for c in args.components.split(",") if c.strip()]
    components = resolve_components(profile, os_tag, override=override)

    if args.identities is not None:
        identity_names = [n.strip() for n in args.identities.split(",") if n.strip()]
    else:
        identity_names = profile["identities"]
    identities = [load_identity(n) for n in identity_names]

    # Apply per-identity overrides from the profile (e.g. force credential_helper
    # = "gcm" for personal/github.com on a work-desktop profile).
    overrides_map = profile.get("identity_overrides", {}) or {}
    for ident in identities:
        ident_overrides = overrides_map.get(ident["name"])
        if ident_overrides:
            _apply_identity_overrides(ident, ident_overrides)

    # Decorate each component with the per-OS script path (if any)
    kind = "linux" if os_tag.startswith("linux") else os_tag
    plan = []
    for m in components:
        script = component_script_path(m["name"], kind)
        plan.append({
            "name": m["name"],
            "description": m.get("description", ""),
            "per_identity": m["per_identity"],
            "script": str(script) if script else None,
            "config": profile["component_config"].get(m["name"], {}),
        })

    print(json.dumps({
        "profile": profile["name"],
        "os_tag": os_tag,
        "components": plan,
        "identities": identities,
    }, indent=2))


def cmd_list_identities(args):
    """List every identity discoverable on this machine (BW registry + TOML).
    With --profile, mark in_profile=true for identities the profile names.
    """
    in_profile: set[str] = set()
    if args.profile:
        try:
            in_profile = set(load_profile(args.profile)["identities"])
        except FileNotFoundError as e:
            sys.exit(f"ERROR: {e}")
    for ident in list_known_identities():
        ident["in_profile"] = ident["name"] in in_profile
        print(json.dumps(ident))


def cmd_list_components(args):
    """List every component for the picker. With --profile, mark which ones
    are in that profile's explicit list (in_profile=true) and filter to those
    supported by the current/--os-tag OS.
    """
    os_tag = args.os_tag or detect_os_tag()
    in_profile: set[str] = set()
    if args.profile:
        try:
            in_profile = set(load_profile(args.profile)["components"])
        except FileNotFoundError as e:
            sys.exit(f"ERROR: {e}")

    for c in list_all_components():
        if os_tag not in c["supported"]:
            continue
        c["in_profile"] = c["name"] in in_profile
        print(json.dumps(c))


def cmd_identity_env(args):
    """Emit identity fields as KEY=value shell-export lines.

    Used by component scripts to consume identity data without parsing TOML.
    """
    ident = load_identity(args.identity)
    print(f"IDENT_NAME={_sh_quote(ident['name'])}")
    print(f"IDENT_GIT_NAME={_sh_quote(ident.get('git_name', ''))}")
    print(f"IDENT_GIT_EMAIL={_sh_quote(ident.get('git_email', ''))}")
    print(f"IDENT_BW_SSH_ITEM={_sh_quote(ident.get('bw_ssh_item', ''))}")
    print(f"IDENT_SSH_KEY_BASENAME={_sh_quote(ident['ssh_key_basename'])}")
    print(f"IDENT_DEFAULT={'1' if ident.get('default') else '0'}")
    print(f"IDENT_APPLIES_TO_JSON={_sh_quote(json.dumps(ident.get('applies_to', [])))}")


def _sh_quote(value: str) -> str:
    return "'" + value.replace("'", "'\\''") + "'"


def main():
    parser = argparse.ArgumentParser()
    sub = parser.add_subparsers(dest="cmd", required=True)

    sub.add_parser("os-tag").set_defaults(func=cmd_os_tag)
    sub.add_parser("list-profiles").set_defaults(func=cmd_list_profiles)

    p_resolve = sub.add_parser("resolve", help="emit JSON plan for a profile")
    p_resolve.add_argument("profile")
    p_resolve.add_argument("--os-tag")
    p_resolve.add_argument("--components", help="comma-separated override of profile.components")
    p_resolve.add_argument("--identities", help="comma-separated override of profile.identities")
    p_resolve.set_defaults(func=cmd_resolve)

    p_listc = sub.add_parser("list-components", help="emit one JSON-per-line for each available component")
    p_listc.add_argument("--profile", help="if given, mark in_profile=true for components in this profile")
    p_listc.add_argument("--os-tag")
    p_listc.set_defaults(func=cmd_list_components)

    p_listi = sub.add_parser("list-identities", help="emit one JSON-per-line for each known identity (registry + TOML)")
    p_listi.add_argument("--profile", help="if given, mark in_profile=true for identities in this profile")
    p_listi.set_defaults(func=cmd_list_identities)

    p_ident = sub.add_parser("identity-env", help="emit KEY=value lines for an identity")
    p_ident.add_argument("identity")
    p_ident.set_defaults(func=cmd_identity_env)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
