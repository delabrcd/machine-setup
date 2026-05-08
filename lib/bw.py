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
    """True if `bw` is on PATH OR present at a well-known per-user location.
    Adds the location to PATH on the fly when found there — handles the case
    where curl|bash gave us a non-interactive shell without ~/.local/bin."""
    if shutil.which("bw"):
        return True
    for candidate in (Path.home() / ".local/bin/bw",
                      Path.home() / ".local/bin/bw.exe",
                      Path("/usr/local/bin/bw")):
        if candidate.is_file() and os.access(candidate, os.X_OK):
            d = str(candidate.parent)
            if d not in os.environ.get("PATH", "").split(os.pathsep):
                os.environ["PATH"] = d + os.pathsep + os.environ.get("PATH", "")
            return True
    return False


def ensure_installed() -> bool:
    """If `bw` isn't on PATH, try to install it. Returns True if bw is
    available afterward.

    Linux/WSL: downloads the official prebuilt zip from GitHub releases into
    ~/.local/bin (no sudo, no system package manager touched). The user can
    `rm ~/.local/bin/bw` to remove it cleanly.

    Windows: tries winget. If unavailable, returns False so the caller can
    fall back to TOML-only identities.
    """
    user_bin = Path.home() / ".local" / "bin"
    user_bin.mkdir(parents=True, exist_ok=True)
    # Ensure user_bin is on PATH BEFORE the have_bw check so a previously-
    # installed binary at ~/.local/bin/bw is detected on every subsequent run
    # (and we don't redownload it).
    if str(user_bin) not in os.environ.get("PATH", "").split(os.pathsep):
        os.environ["PATH"] = str(user_bin) + os.pathsep + os.environ.get("PATH", "")

    if have_bw():
        return True

    if sys.platform == "win32":
        return _install_bw_windows()
    return _install_bw_unix(user_bin)


def _install_bw_windows() -> bool:
    if not shutil.which("winget"):
        _warn("winget not available — install Bitwarden CLI manually from https://bitwarden.com/help/cli/")
        return False
    _log("Installing Bitwarden CLI via winget...")
    rc = subprocess.call([
        "winget", "install", "--id", "Bitwarden.CLI", "--silent",
        "--accept-source-agreements", "--accept-package-agreements",
    ])
    # Refresh PATH from registry
    import ctypes  # only on win32
    try:
        machine_path = subprocess.check_output(
            ["reg", "query", "HKLM\\SYSTEM\\CurrentControlSet\\Control\\Session Manager\\Environment", "/v", "Path"],
            text=True,
        )
        # crude parse — winget typically updates the env vars but the current
        # process won't see them until refresh. Just merge what we have.
        os.environ["PATH"] = (
            os.environ.get("PATH", "")
            + os.pathsep
            + r"C:\Program Files\Bitwarden CLI"
        )
    except Exception:
        pass
    return have_bw()


def _install_bw_unix(user_bin: Path) -> bool:
    import io, json, urllib.request, zipfile

    arch = "linux"
    # bitwarden ships only x64 prebuilt for linux as of 2025; arm64 users would
    # need npm or snap. Detect and bail out for non-x64 arches.
    machine = (subprocess.check_output(["uname", "-m"], text=True).strip()
               if shutil.which("uname") else "x86_64")
    if machine not in ("x86_64", "amd64"):
        _warn(f"No prebuilt bw binary for {machine}. Install via: npm i -g @bitwarden/cli")
        return False

    _log("Installing Bitwarden CLI...")
    # Find the latest cli-v* tag
    try:
        req = urllib.request.Request(
            "https://api.github.com/repos/bitwarden/clients/releases?per_page=40",
            headers={"Accept": "application/vnd.github+json", "User-Agent": "machine-setup"},
        )
        with urllib.request.urlopen(req, timeout=15) as resp:
            releases = json.loads(resp.read())
    except Exception as e:
        _warn(f"Could not fetch BW CLI releases ({e})")
        return False

    version: str | None = None
    asset_url: str | None = None
    for r in releases:
        tag = r.get("tag_name", "")
        if not tag.startswith("cli-v"):
            continue
        ver = tag[len("cli-v"):]
        for a in r.get("assets") or []:
            name = a.get("name", "")
            if name == f"bw-oss-{arch}-{ver}.zip" or name == f"bw-{arch}-{ver}.zip":
                version = ver
                asset_url = a.get("browser_download_url")
                break
        if asset_url:
            break

    if not asset_url:
        _warn("No bw-linux zip found in recent releases")
        return False

    _log(f"  downloading {asset_url}")
    try:
        with urllib.request.urlopen(asset_url, timeout=60) as resp:
            data = resp.read()
    except Exception as e:
        _warn(f"Download failed ({e})")
        return False

    try:
        with zipfile.ZipFile(io.BytesIO(data)) as zf:
            # The zip contains a single `bw` executable
            for name in zf.namelist():
                if name.endswith("bw") or name == "bw":
                    member = zf.read(name)
                    target = user_bin / "bw"
                    target.write_bytes(member)
                    target.chmod(0o755)
                    break
            else:
                _warn("zip did not contain a bw binary")
                return False
    except Exception as e:
        _warn(f"Extraction failed ({e})")
        return False

    if have_bw():
        _log(f"  bw installed: {shutil.which('bw')} (version {version})")
        return True
    _warn("bw still not on PATH after install")
    return False


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
    proc = subprocess.run(["bw", "sync"], capture_output=True, text=True)
    if proc.returncode != 0:
        # Surface the failure rather than swallowing it — a silent sync error
        # leads to "I added the field but the bootstrap can't see it" mysteries.
        _warn(f"bw sync failed (rc={proc.returncode}): {(proc.stderr or proc.stdout).strip()}")


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
