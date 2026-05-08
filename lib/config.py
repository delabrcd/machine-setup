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


def _bw_cache_dir() -> Path | None:
    """Runtime cache where the bootstrap drops BW-discovered profiles.
    Treated as a third overlay layer between local/ and repo/.
    """
    p = os.environ.get("MACHINE_SETUP_BW_CACHE_DIR")
    return Path(p) if p else None


def _profile_search_bases() -> list[tuple[Path, str]]:
    """Search bases for profiles, in precedence order. Returns (path, label)."""
    bases: list[tuple[Path, str]] = [(LOCAL, "local")]
    bw = _bw_cache_dir()
    if bw is not None:
        bases.append((bw, "bitwarden"))
    bases.append((REPO, "repo"))
    return bases


def _load_toml(path: Path) -> dict:
    with path.open("rb") as f:
        return tomllib.load(f)


def _resolve(kind: str, name: str) -> Path:
    """Find <kind>/<name>.toml in overlays. Precedence:
       local/ > BW-cache (profiles only) > repo/
    """
    bases: list[Path]
    if kind == "profiles":
        bases = [b[0] for b in _profile_search_bases()]
    else:
        bases = [LOCAL, REPO]
    for base in bases:
        candidate = base / kind / f"{name}.toml"
        if candidate.exists():
            return candidate
    raise FileNotFoundError(f"{kind}/{name}.toml not found in any overlay")


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
    """All profiles known across overlays, deduped by name in precedence
    order (local wins over BW-cache wins over repo)."""
    seen: dict[str, dict] = {}
    # Walk in REVERSE precedence so high-precedence layers overwrite the dict
    bases = list(reversed(_profile_search_bases()))
    for base, label in bases:
        d = base / "profiles"
        if not d.is_dir():
            continue
        for p in sorted(d.glob("*.toml")):
            data = _load_toml(p)
            name = data.get("name") or p.stem
            seen[name] = {
                "name": name,
                "description": data.get("description", ""),
                "source": label,
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
    # Soft ordering: if BOTH are in the plan, this component runs after the
    # listed ones. Doesn't pull them in transitively. Use for components
    # whose runtime configuration (e.g. chezmoi MCP registration) depends on
    # outputs of an optional sibling.
    data.setdefault("runs_after", [])
    data.setdefault("per_identity", False)
    # If true, the TUI suspends and the component gets the bare terminal
    # (for sudo prompts, nested bootstraps inside WSL, etc.). Output is NOT
    # captured into the RichLog for these.
    data.setdefault("requires_tty", False)
    return data


def resolve_components(profile: dict, os_tag: str, override: list[str] | None = None) -> list[dict]:
    """Topo-sort components, pulling in transitive `depends_on` deps and
    honoring `runs_after` soft-ordering when both ends are in the plan.

    os_tag is one of: linux-ubuntu, linux-fedora, linux-arch, windows, wsl, macos.
    Components whose `supported` list omits os_tag are skipped silently — that's
    how a single profile works on multiple OSes (e.g. uv on Linux only).

    If `override` is given, it replaces the profile's components list entirely
    (deps are still pulled in transitively).
    """
    explicit = list(override if override is not None else profile["components"])

    # First pass: include everything reachable via depends_on.
    in_plan: set[str] = set()
    def collect(comp_name: str, stack: tuple[str, ...] = ()):
        if comp_name in in_plan:
            return
        if comp_name in stack:
            raise ValueError(f"component dep cycle: {' -> '.join(stack + (comp_name,))}")
        manifest = load_component_manifest(comp_name)
        for dep in manifest["depends_on"]:
            collect(dep, stack + (comp_name,))
        in_plan.add(comp_name)
    for c in explicit:
        collect(c)

    # Second pass: build the dependency graph. depends_on always adds an edge.
    # runs_after adds an edge only if BOTH endpoints are in_plan (soft order).
    edges: dict[str, set[str]] = {n: set() for n in in_plan}  # name -> set of preds
    for n in in_plan:
        m = load_component_manifest(n)
        for dep in m["depends_on"]:
            if dep in in_plan:
                edges[n].add(dep)
        for soft in m.get("runs_after") or []:
            if soft in in_plan:
                edges[n].add(soft)

    # Kahn's algorithm — ordered visitation so output is stable.
    out_order: list[str] = []
    no_pred = sorted([n for n, p in edges.items() if not p])
    pred_of = {n: set(p) for n, p in edges.items()}
    succ_of: dict[str, set[str]] = {n: set() for n in in_plan}
    for n, preds in edges.items():
        for p in preds:
            succ_of[p].add(n)
    while no_pred:
        n = no_pred.pop(0)
        out_order.append(n)
        for s in sorted(succ_of[n]):
            pred_of[s].discard(n)
            if not pred_of[s]:
                no_pred.append(s)
                no_pred.sort()
    if len(out_order) != len(in_plan):
        # Some cycle escaped the depends_on check (likely runs_after vs depends_on contradiction)
        leftover = [n for n in in_plan if n not in out_order]
        raise ValueError(f"runs_after/depends_on cycle involving: {leftover}")

    out = []
    for c in out_order:
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

    # Skip identities that aren't in the registry or any TOML file. Common when
    # a saved selection lists names that were renamed/deleted, or when BW
    # discovery failed and the saved name no longer resolves. Crashing the
    # whole bootstrap over a stale selection is worse than dropping the
    # identity and letting per-identity components no-op for that name.
    identities = []
    for n in identity_names:
        try:
            identities.append(load_identity(n))
        except FileNotFoundError:
            print(f"  WARN: identity '{n}' not found in registry or TOML — skipping", file=sys.stderr)

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


def _required_components(identity_names: list[str], os_tag: str) -> list[str]:
    """Components implied by the user's identity selection + the OS.
    The resolver pulls transitive deps in on top of this (e.g. nvm).
    """
    required: list[str] = ["packages"]
    if os_tag == "wsl":
        required.append("wsl-interop")
    if not identity_names:
        return required
    # Anything identity-aware needs these
    required.extend(["git-base", "git-identity", "bw-cli"])
    for name in identity_names:
        try:
            ident = load_identity(name)
        except FileNotFoundError:
            continue
        if ident.get("bw_ssh_item") and "ssh-key" not in required:
            required.append("ssh-key")
        if any(
            (at.get("credential_helper") or "").lower() not in ("", "none")
            for at in ident.get("applies_to", [])
        ) and "credential-helpers" not in required:
            required.append("credential-helpers")
    return required


def _convert_machine_overrides(raw: dict) -> dict:
    """Convert machine.toml-shape identity overrides to the profile-shape
    consumed by _apply_identity_overrides.

    machine.toml:
        [identity_overrides.personal."github.com"]
        credential_helper = "gcm"

    profile-shape (what _apply_identity_overrides expects):
        applies_to = [{host: "github.com", credential_helper: "gcm"}]
        plus any non-host top-level overrides
    """
    if not raw:
        return {}
    applies_to: list[dict] = []
    top_level: dict = {}
    for k, v in raw.items():
        if isinstance(v, dict):
            entry = {"host": k}
            entry.update(v)
            applies_to.append(entry)
        else:
            top_level[k] = v
    out = dict(top_level)
    if applies_to:
        out["applies_to"] = applies_to
    return out


def cmd_derive_components(args):
    os_tag = args.os_tag or detect_os_tag()
    identity_names = [n.strip() for n in (args.identities or "").split(",") if n.strip()]
    print(json.dumps(_required_components(identity_names, os_tag)))


def cmd_plan(args):
    """Build a resolution plan from per-machine inputs — no profile concept.

    Args:
        --identities CSV
        --extra-components CSV
        --identity-overrides JSON (machine.toml shape: {name: {host: {field: val}}})
        --component-config JSON ({comp: {field: val}})
        --os-tag (optional, detected if absent)
    """
    os_tag = args.os_tag or detect_os_tag()
    identity_names = [n.strip() for n in (args.identities or "").split(",") if n.strip()]
    extra_components = [c.strip() for c in (args.extra_components or "").split(",") if c.strip()]
    identity_overrides = json.loads(args.identity_overrides or "{}")
    component_config = json.loads(args.component_config or "{}")

    required = _required_components(identity_names, os_tag)

    # Explicit list = required + user-picked extras (deduped, required first)
    seen = set()
    explicit: list[str] = []
    for c in required + extra_components:
        if c not in seen:
            explicit.append(c)
            seen.add(c)

    profile = {
        "name": "_machine",
        "components": explicit,
        "identities": identity_names,
        "component_config": component_config,
    }
    components = resolve_components(profile, os_tag)

    identities = []
    for n in identity_names:
        try:
            identities.append(load_identity(n))
        except FileNotFoundError:
            print(f"  WARN: identity '{n}' not found in registry or TOML — skipping", file=sys.stderr)

    for ident in identities:
        raw = identity_overrides.get(ident["name"])
        if raw:
            _apply_identity_overrides(ident, _convert_machine_overrides(raw))

    kind = "linux" if os_tag.startswith("linux") else os_tag
    plan = []
    required_set = set(required)
    for m in components:
        script = component_script_path(m["name"], kind)
        plan.append({
            "name": m["name"],
            "description": m.get("description", ""),
            "per_identity": m["per_identity"],
            "script": str(script) if script else None,
            "config": component_config.get(m["name"], {}),
            "required": m["name"] in required_set,
        })

    print(json.dumps({
        "os_tag": os_tag,
        "components": plan,
        "identities": identities,
    }, indent=2))


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

    p_derive = sub.add_parser("derive-components", help="emit JSON list of required components for given identities + OS")
    p_derive.add_argument("--identities", help="comma-separated identity names")
    p_derive.add_argument("--os-tag")
    p_derive.set_defaults(func=cmd_derive_components)

    p_plan = sub.add_parser("plan", help="build a plan from machine inputs (no profile)")
    p_plan.add_argument("--identities")
    p_plan.add_argument("--extra-components")
    p_plan.add_argument("--identity-overrides")
    p_plan.add_argument("--component-config")
    p_plan.add_argument("--os-tag")
    p_plan.set_defaults(func=cmd_plan)

    p_ident = sub.add_parser("identity-env", help="emit KEY=value lines for an identity")
    p_ident.add_argument("identity")
    p_ident.set_defaults(func=cmd_identity_env)

    args = parser.parse_args()
    args.func(args)


if __name__ == "__main__":
    main()
