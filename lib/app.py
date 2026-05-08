#!/usr/bin/env python3
"""Full-screen Textual TUI for the bootstrap.

Drives the entire interactive phase:
    Step 1/4 — Bitwarden unlock + identity discovery (auto)
    Step 2/4 — Identity selection
    Step 3/4 — Per-identity auth
    Step 4/4 — Component selection
    Step 5/4 — Component configuration

After the last screen, the app exits and main.py runs sudo -v + plan
execution in the plain terminal (component output is more useful seen
directly than captured in a panel).
"""
from __future__ import annotations
from pathlib import Path
import json, os, re, sys

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import VerticalScroll, Vertical, Center
from textual.screen import Screen
from textual.widgets import (
    Footer, Header, Input, ProgressBar, RadioButton, RadioSet,
    RichLog, SelectionList, Static, TextArea,
)
from textual.widgets.selection_list import Selection

# Local modules — sys.path was set up by main.py before launching us
import bw            # noqa: E402
import config        # noqa: E402
import driver        # noqa: E402
import identity_ops  # noqa: E402


_NEW_IDENT_TAG = "__create_new_identity__"
_BW_MANAGER_TAG = "__bw_manager__"


def _safe_id(s: str) -> str:
    """Textual widget IDs can only contain letters, digits, _ and -. Slugify."""
    return re.sub(r"[^A-Za-z0-9_-]", "_", s)


# ── Loading / unlock screens ────────────────────────────────────────────────

class UnlockScreen(Screen):
    """Prompt for the Bitwarden master password and unlock the vault.
    Skipped automatically if BW_SESSION is already valid.
    """
    BINDINGS = [Binding("escape", "abort", "Cancel")]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Bitwarden", classes="step")
            yield Static(
                "Enter your Bitwarden master password to unlock the vault.\n"
                "(Press ENTER to submit, Escape to cancel.)",
                classes="hint",
            )
            yield Input(password=True, placeholder="master password", id="pw")
            yield Static(id="unlock-status", classes="status")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#pw", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id != "pw":
            return
        os.environ["BW_PASSWORD"] = event.value
        status: Static = self.query_one("#unlock-status", Static)
        status.update("Unlocking...")
        self.run_worker(self._do_unlock(), thread=True, exclusive=True)

    async def _do_unlock(self) -> None:
        ok = bw.unlock()
        os.environ.pop("BW_PASSWORD", None)
        status: Static = self.query_one("#unlock-status", Static)
        if not ok:
            self.app.call_from_thread(status.update, "Wrong password — try again, or Esc to cancel.")
            self.app.call_from_thread(self.query_one("#pw", Input).focus)
            return
        # Move on to discovery
        self.app.call_from_thread(self.app.advance_after_unlock)

    def action_abort(self) -> None:
        self.app.exit({"action": "abort"})


class DiscoveryScreen(Screen):
    """Brief status screen while we discover identities + build the initial
    plan inputs. Rolls straight into IdentityScreen when done."""

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Bitwarden", classes="step")
            yield Static("Discovering identities + computing required components...", id="disc-status", classes="hint")
        yield Footer()

    def on_mount(self) -> None:
        self.run_worker(self._do_discovery(), thread=True, exclusive=True)

    async def _do_discovery(self) -> None:
        bw.write_identity_registry(self.app.registry_file)
        os.environ["MACHINE_SETUP_IDENTITY_REGISTRY"] = str(self.app.registry_file)

        # Populate app fields used by later screens
        self.app.available_idents = config.list_known_identities()
        self.app.all_components = [
            c for c in config.list_all_components()
            if self.app.os_tag in c.get("supported", [])
        ]

        # If the vault has zero Machine Identity items AND zero MCP secrets,
        # this is a fresh first-time setup — push the BW manager so the user
        # can create everything before the picker. They get back to the
        # picker via the manager's "Done" button.
        try:
            ident_count = len(identity_ops.list_identity_names())
            secrets     = identity_ops.read_mcp_secrets()
            secrets_set = sum(1 for v in secrets.values() if v)
        except Exception:
            ident_count = -1
            secrets_set = -1
        if ident_count == 0 and secrets_set == 0:
            self.app.call_from_thread(self.app.advance_to_identity)
            self.app.call_from_thread(self.app.push_screen, BwManagerScreen())
        else:
            self.app.call_from_thread(self.app.advance_to_identity)


# ── Identity screen ─────────────────────────────────────────────────────────

class IdentityScreen(Screen):
    BINDINGS = [
        Binding("ctrl+s", "advance", "Continue"),
        Binding("escape", "back",    "Cancel"),
    ]

    def __init__(self, available: list[dict], selected: list[str]):
        super().__init__()
        self.available = available
        self._initial = set(selected)

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Step 1 of 4 — Identities", classes="step")
            yield Static(
                "Pick which identities to install on this machine.\n"
                "Space toggles, Ctrl+S to continue.",
                classes="hint",
            )
            options = [
                Selection("[~] Manage Bitwarden config (identities + MCP secrets)...",
                          _BW_MANAGER_TAG, False),
                Selection("[+] Create new identity in Bitwarden...",
                          _NEW_IDENT_TAG, False),
            ]
            for ident in self.available:
                src = ident.get("source", "")
                gn  = ident.get("git_name", "")
                ge  = ident.get("git_email", "")
                suffix = f"{gn} <{ge}>" if ge else "(no email)"
                label = f"{ident['name']:<15} {suffix}  [{src}]"
                options.append(Selection(label, ident["name"], ident["name"] in self._initial))
            yield SelectionList[str](*options, id="ident-list")
        yield Footer()

    def action_advance(self) -> None:
        sl: SelectionList = self.query_one("#ident-list", SelectionList)
        picked = list(sl.selected)
        if _BW_MANAGER_TAG in picked:
            self.app.state["identities"] = [p for p in picked if p not in (_BW_MANAGER_TAG, _NEW_IDENT_TAG)]
            self.app.push_screen(BwManagerScreen())
            return
        if _NEW_IDENT_TAG in picked:
            self.app.state["identities"] = [p for p in picked if p != _NEW_IDENT_TAG]
            self.app.push_screen(IdentityFormScreen(mode="create"))
            return
        self.app.state["identities"] = picked
        self.app.advance_to_auth()

    def action_back(self) -> None:
        self.app.exit({"action": "abort"})


# ── Auth screen ─────────────────────────────────────────────────────────────

HELPER_OPTIONS = [
    ("ssh",       "ssh        — SSH-only (recommended for personal hosts)"),
    ("gcm",       "gcm        — Git Credential Manager (HTTPS via OAuth, SSO)"),
    ("bitwarden", "bitwarden  — username/api-token from a BW item (Linux only)"),
    ("none",      "none       — no helper"),
]


class AuthScreen(Screen):
    BINDINGS = [
        Binding("ctrl+s", "advance", "Continue"),
        Binding("escape", "back",    "Back"),
    ]

    def __init__(self, pairs: list[dict], current: dict):
        super().__init__()
        self.pairs = pairs
        self.current = dict(current)

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Step 2 of 4 — Per-identity auth", classes="step")
            if not self.pairs:
                yield Static("No identity declares any host — nothing to configure here.\nCtrl+S to continue.", classes="hint")
            else:
                yield Static(
                    "Choose a credential helper for each identity-host pair.\n"
                    "Tab between groups, arrows to choose, Ctrl+S to continue.",
                    classes="hint",
                )
                for pair in self.pairs:
                    ident, host = pair["identity"], pair["host"]
                    default = pair.get("current_helper") or "ssh"
                    yield Static(f"\n[bold]{ident}[/] on [bold]{host}[/]", classes="auth-title")
                    rs_id = f"rs-{_safe_id(ident)}-{_safe_id(host)}"
                    buttons = [
                        RadioButton(label, value=(v == default), name=v)
                        for v, label in HELPER_OPTIONS
                    ]
                    yield RadioSet(*buttons, id=rs_id)
        yield Footer()

    def action_advance(self) -> None:
        out = dict(self.current)
        for pair in self.pairs:
            ident, host = pair["identity"], pair["host"]
            rs_id = f"rs-{_safe_id(ident)}-{_safe_id(host)}"
            try:
                rs: RadioSet = self.query_one(f"#{rs_id}", RadioSet)
            except Exception:
                continue
            pressed = rs.pressed_button
            value = pressed.name if pressed else (pair.get("current_helper") or "ssh")
            out.setdefault(ident, {}).setdefault(host, {})["credential_helper"] = value
        self.app.state["identity_overrides"] = out
        self.app.advance_to_components()

    def action_back(self) -> None:
        self.app.advance_to_identity()


# ── Components screen ───────────────────────────────────────────────────────

class ComponentScreen(Screen):
    BINDINGS = [
        Binding("ctrl+s", "advance", "Continue"),
        Binding("escape", "back",    "Back"),
    ]

    def __init__(self, required: list[str], optional: list[dict], selected: list[str], identities: list[str], os_tag: str):
        super().__init__()
        self.required = required
        self.optional = optional
        self._initial = set(selected)
        self.identities = identities
        self.os_tag = os_tag

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Step 3 of 4 — Components", classes="step")
            yield Static(
                "Required components are auto-installed. Toggle optional ones below.\n"
                "Selecting an optional with deps auto-pulls them in (visible in the preview).\n"
                "Space to toggle, Ctrl+S to continue.",
                classes="hint",
            )
            options = [
                Selection(
                    f"{c['name']:<22} {c.get('description','')[:60]}",
                    c["name"],
                    c["name"] in self._initial,
                )
                for c in self.optional
            ]
            if options:
                yield SelectionList[str](*options, id="comp-list")
            else:
                yield Static("(no optional components for this OS)", classes="hint")
            yield Static("", id="plan-preview", classes="plan-preview")
        yield Footer()

    def on_mount(self) -> None:
        self._refresh_preview()

    def on_selection_list_selected_changed(self, _event) -> None:
        self._refresh_preview()

    def _refresh_preview(self) -> None:
        try:
            sl: SelectionList = self.query_one("#comp-list", SelectionList)
            user_picks = list(sl.selected)
        except Exception:
            user_picks = []

        # Resolve the full set that would actually install given current picks.
        explicit = list(set(self.required) | set(user_picks))
        profile = {
            "name": "_preview",
            "components": explicit,
            "identities": self.identities,
            "component_config": {},
        }
        try:
            resolved = config.resolve_components(profile, self.os_tag)
            full_names = [c["name"] for c in resolved]
        except Exception as e:
            full_names = explicit
            self.query_one("#plan-preview", Static).update(f"[red]preview error: {e}[/]")
            return

        required_set = set(self.required)
        user_set = set(user_picks)
        auto_only = [n for n in full_names if n not in required_set and n not in user_set]

        # Compute "auto-pulled by which" so the user understands the chain.
        # For each auto, walk through user_picks + required and see whose
        # depends_on graph reaches it.
        attribution: dict[str, list[str]] = {n: [] for n in auto_only}
        try:
            for picked in user_picks:
                stack = [picked]
                seen = {picked}
                while stack:
                    cur = stack.pop()
                    manifest = config.load_component_manifest(cur)
                    for dep in manifest.get("depends_on") or []:
                        if dep in seen:
                            continue
                        seen.add(dep)
                        stack.append(dep)
                        if dep in attribution:
                            attribution[dep].append(picked)
        except Exception:
            pass

        lines = ["[bold]Plan preview:[/]"]
        if self.required:
            lines.append(f"  [green]Required[/]    : {', '.join(self.required)}")
        if user_picks:
            lines.append(f"  [yellow]Your picks[/]  : {', '.join(user_picks)}")
        if auto_only:
            parts = []
            for name in auto_only:
                via = attribution.get(name) or []
                via_txt = f" (via {', '.join(via)})" if via else ""
                parts.append(f"{name}{via_txt}")
            lines.append(f"  [cyan]Auto-pulled[/] : {', '.join(parts)}")
        if not user_picks and not auto_only:
            lines.append("  (only required components will install)")

        self.query_one("#plan-preview", Static).update("\n".join(lines))

    def action_advance(self) -> None:
        try:
            sl: SelectionList = self.query_one("#comp-list", SelectionList)
            self.app.state["extra_components"] = list(sl.selected)
        except Exception:
            self.app.state["extra_components"] = []
        self.app.advance_to_config()

    def action_back(self) -> None:
        self.app.advance_to_auth()


# ── Config screen ───────────────────────────────────────────────────────────

CONFIG_SCHEMA: dict[str, list[tuple[str, str, str | None]]] = {
    # chezmoi-source ships inside this repo at $MACHINE_SETUP_DIR/chezmoi-source
    # so no repo URL prompt is needed. Override via machine.toml's
    # [component_config.chezmoi].source if you want a different source dir.
    # dev-utilities + bitbucket-mcp are gone (replaced by aashari MCP via npx).
    "wsl-bootstrap": [
        ("distro", "WSL distro name", "Ubuntu"),
    ],
}


class ConfigScreen(Screen):
    BINDINGS = [
        Binding("ctrl+s", "advance", "Finish"),
        Binding("escape", "back",    "Back"),
    ]

    def __init__(self, plan_components: list[str], current_config: dict):
        super().__init__()
        self.plan_components = plan_components
        self.current = {k: dict(v) for k, v in current_config.items()}
        self._needed: list[tuple[str, str, str, str | None]] = []
        for comp, fields in CONFIG_SCHEMA.items():
            if comp not in plan_components:
                continue
            for field, label, default in fields:
                self._needed.append((comp, field, label, default))

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Step 4 of 4 — Component configuration", classes="step")
            if not self._needed:
                yield Static("No selected component needs additional config.\nCtrl+S to finish.", classes="hint")
            else:
                yield Static(
                    "Fill in any missing values. Tab between fields, Ctrl+S to finish.",
                    classes="hint",
                )
                for comp, field, label, default in self._needed:
                    existing = (self.current.get(comp) or {}).get(field, "")
                    initial = existing or (default or "")
                    yield Static(f"\n[bold]{comp}.{field}[/]  — {label}", classes="cfg-title")
                    inp_id = f"in-{_safe_id(comp)}-{_safe_id(field)}"
                    yield Input(value=initial, placeholder=default or "", id=inp_id)
        yield Footer()

    def action_advance(self) -> None:
        out = {k: dict(v) for k, v in self.current.items()}
        for comp, field, _label, default in self._needed:
            inp_id = f"in-{_safe_id(comp)}-{_safe_id(field)}"
            try:
                inp: Input = self.query_one(f"#{inp_id}", Input)
            except Exception:
                continue
            val = (inp.value or "").strip()
            if not val and default:
                val = default
            if val:
                out.setdefault(comp, {})[field] = val
        self.app.state["component_config"] = out
        self.app.advance_to_sudo()

    def action_back(self) -> None:
        self.app.advance_to_components()


# ── Sudo screen ─────────────────────────────────────────────────────────────

class SudoScreen(Screen):
    """Capture the sudo password once + cache via `sudo -S -v` so component
    scripts (apt/dnf/pacman/etc.) don't prompt during the install run."""

    BINDINGS = [
        Binding("escape", "skip", "Skip (sudo will prompt during install)"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Sudo", classes="step")
            yield Static(
                "System packages need sudo. Enter your sudo password to cache it for the install,\n"
                "or press Esc to skip and let sudo prompt during the install (uglier).",
                classes="hint",
            )
            yield Input(password=True, placeholder="sudo password", id="sudo-pw")
            yield Static(id="sudo-status", classes="status")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#sudo-pw", Input).focus()

    def on_input_submitted(self, event: Input.Submitted) -> None:
        if event.input.id != "sudo-pw":
            return
        pw = event.value
        self.query_one("#sudo-status", Static).update("Validating...")
        self.run_worker(self._cache_sudo(pw), thread=True, exclusive=True)

    async def _cache_sudo(self, pw: str) -> None:
        import subprocess as sp
        proc = sp.run(
            ["sudo", "-S", "-v"],
            input=pw + "\n",
            capture_output=True, text=True,
        )
        status: Static = self.query_one("#sudo-status", Static)
        if proc.returncode == 0:
            self.app.state["_sudo_cached"] = True
            self.app.call_from_thread(self.app.advance_to_run)
        else:
            self.app.call_from_thread(status.update, "Wrong password — try again, or Esc to skip.")
            self.app.call_from_thread(self.query_one("#sudo-pw", Input).focus)

    def action_skip(self) -> None:
        self.app.state["_sudo_cached"] = False
        self.app.advance_to_run()


# ── Run-plan screen ─────────────────────────────────────────────────────────

class RunPlanScreen(Screen):
    """Execute the resolved plan inside the TUI, streaming each component's
    output into a RichLog. Subprocess captures stdout+stderr line by line and
    pushes them onto the UI thread via call_from_thread.
    """
    BINDINGS = [Binding("q", "quit", "Quit")]

    def __init__(self, plan: dict, machine_setup_dir: Path):
        super().__init__()
        self.plan = plan
        self.machine_setup_dir = machine_setup_dir
        self.failed: list[str] = []
        self._done = False

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with Vertical():
            yield Static("Running plan...", id="run-status", classes="step")
            total = max(1, sum(
                len(self.plan["identities"]) if c["per_identity"] else 1
                for c in self.plan["components"]
            ))
            yield ProgressBar(total=total, show_eta=False, id="run-progress")
            yield RichLog(id="run-log", markup=True, max_lines=4000, auto_scroll=True)
        yield Footer()

    def on_mount(self) -> None:
        self.run_worker(self._run_all(), thread=True, exclusive=True)

    # ── Worker ─────────────────────────────────────────────────────────────

    def _write(self, text: str) -> None:
        rl: RichLog = self.query_one("#run-log", RichLog)
        rl.write(text)

    def _set_status(self, text: str) -> None:
        self.query_one("#run-status", Static).update(text)

    def _advance_progress(self) -> None:
        self.query_one("#run-progress", ProgressBar).advance(1)

    def _build_env(self, comp: dict, ident: dict | None) -> dict:
        env = os.environ.copy()
        env["MACHINE_SETUP_DIR"] = str(self.machine_setup_dir)
        env["COMPONENT_CONFIG_JSON"] = json.dumps(comp.get("config") or {})
        env["PLAN_JSON"] = json.dumps(self.plan)
        env["MACHINE_SETUP_NONINTERACTIVE"] = "1"
        if ident:
            env.update({
                "IDENT_NAME":             ident["name"],
                "IDENT_GIT_NAME":         ident.get("git_name", ""),
                "IDENT_GIT_EMAIL":        ident.get("git_email", ""),
                "IDENT_BW_SSH_ITEM":      ident.get("bw_ssh_item", ""),
                "IDENT_SSH_KEY_BASENAME": ident.get("ssh_key_basename", f"id_ed25519_{ident['name']}"),
                "IDENT_DEFAULT":          "1" if ident.get("default") else "0",
                "IDENT_APPLIES_TO_JSON":  json.dumps(ident.get("applies_to", [])),
            })
        return env

    def _build_cmd(self, comp: dict) -> list[str] | None:
        import shlex
        from shutil import which
        script = comp["script"]
        if script.endswith(".ps1"):
            ps = which("pwsh") or which("powershell")
            if not ps:
                return None
            return [ps, "-NoProfile", "-ExecutionPolicy", "Bypass", "-File", script]
        common = self.machine_setup_dir / "lib" / "common.sh"
        return ["bash", "-c",
                f". {shlex.quote(str(common))}; . {shlex.quote(script)}"]

    def _run_one(self, comp: dict, ident: dict | None) -> int:
        """Run a single component, streaming output into the log."""
        import subprocess
        env = self._build_env(comp, ident)
        cmd = self._build_cmd(comp)
        if cmd is None:
            self.app.call_from_thread(self._write, "[red]  no interpreter for this OS[/]")
            return 1

        # `requires_tty` components hand the terminal back — needed for nested
        # bootstraps inside WSL where sudo + BW prompts must reach the user.
        if comp.get("requires_tty"):
            return self._run_with_suspend(cmd, env, comp["name"])

        proc = subprocess.Popen(
            cmd, env=env,
            stdout=subprocess.PIPE, stderr=subprocess.STDOUT,
            text=True, bufsize=1,
        )
        assert proc.stdout is not None
        for line in proc.stdout:
            self.app.call_from_thread(self._write, line.rstrip("\n"))
        return proc.wait()

    def _run_with_suspend(self, cmd: list[str], env: dict, name: str) -> int:
        """Suspend Textual for the duration of a subprocess so the user has a
        normal terminal (sudo prompts, nested bootstrap, etc.). Returns exit
        code. Worker thread blocks until the main-thread suspended block
        returns."""
        import subprocess, threading
        result = {"rc": 0}
        done = threading.Event()

        def _on_main():
            try:
                with self.app.suspend():
                    print()
                    print(f">>> {name}: handing terminal over (Textual suspended)")
                    print()
                    result["rc"] = subprocess.call(cmd, env=env)
                    print()
                    print(f"<<< {name}: exit {result['rc']}")
                    try:
                        input("Press ENTER to return to the TUI...")
                    except (EOFError, KeyboardInterrupt):
                        pass
            finally:
                done.set()

        self.app.call_from_thread(_on_main)
        done.wait()
        return result["rc"]

    async def _run_all(self) -> None:
        for comp in self.plan["components"]:
            name = comp["name"]
            self.app.call_from_thread(self._set_status, f"Running: {name}")
            self.app.call_from_thread(self._write, f"\n[bold cyan]── {name} ──[/]")

            if not comp["script"]:
                # No implementation for this OS. On Windows this is the common
                # case for WSL-only components like bitbucket-mcp / uv — they
                # actually run inside WSL, propagated via wsl-bootstrap.
                self.app.call_from_thread(
                    self._write,
                    f"[dim]  delegated to WSL via wsl-bootstrap[/]"
                    if sys.platform == "win32"
                    else f"  no implementation for this OS — skipping",
                )
                self.app.call_from_thread(self._advance_progress)
                continue

            if comp["per_identity"]:
                if not self.plan["identities"]:
                    self.app.call_from_thread(
                        self._write,
                        f"  per-identity component but no identities chosen — skipping",
                    )
                    self.app.call_from_thread(self._advance_progress)
                    continue
                for ident in self.plan["identities"]:
                    self.app.call_from_thread(
                        self._write, f"[dim]  ↳ identity: {ident['name']}[/]"
                    )
                    rc = self._run_one(comp, ident)
                    if rc != 0:
                        self.failed.append(f"{name} [{ident['name']}]")
                        self.app.call_from_thread(
                            self._write,
                            f"[red]  ✗ failed for {ident['name']} (exit {rc})[/]",
                        )
                    self.app.call_from_thread(self._advance_progress)
            else:
                rc = self._run_one(comp, None)
                if rc != 0:
                    self.failed.append(name)
                    self.app.call_from_thread(self._write, f"[red]  ✗ failed (exit {rc})[/]")
                self.app.call_from_thread(self._advance_progress)

        # Done
        self._done = True
        if not self.failed:
            self.app.call_from_thread(self._set_status, "[bold green]✓ Bootstrap complete[/]")
            self.app.call_from_thread(self._write, "\n[bold green]All components succeeded.[/]")
        else:
            self.app.call_from_thread(
                self._set_status,
                f"[bold yellow]Finished with {len(self.failed)} failure(s)[/]",
            )
            self.app.call_from_thread(self._write, "\n[bold yellow]Failed:[/]")
            for f in self.failed:
                self.app.call_from_thread(self._write, f"  - {f}")
        self.app.call_from_thread(self._write, "\n[dim]Press q to quit.[/]")

    def action_quit(self) -> None:
        if not self._done:
            # Allow forceful quit mid-run too
            pass
        self.app.exit({
            "action": "done",
            "state":  self.app.state,
            "failed": self.failed,
        })


# ── BW config wizard screens ────────────────────────────────────────────────

from textual.widgets import Button  # placed near the screens that use it


def _refresh_app_identities(app: "BootstrapApp") -> None:
    """After a BW write, re-discover identities + repopulate the registry so
    the picker reflects the new state on its next render."""
    try:
        bw.write_identity_registry(app.registry_file)
        app.available_idents = config.list_known_identities()
    except Exception:
        pass


class BwManagerScreen(Screen):
    """Hub screen for managing the Bitwarden vault contents that machine-
    setup cares about: Machine Identity items + the MCP-secrets item.
    Pushed from IdentityScreen via the [~] entry, OR auto-pushed on first
    run when the vault is empty."""
    BINDINGS = [Binding("escape", "back", "Back to picker")]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Bitwarden config", classes="step")
            yield Static(
                "Set up the BW items machine-setup expects: one or more\n"
                "'Machine Identity: <name>' items + 'Claude Code MCP Secrets'.",
                classes="hint",
            )

            # Existing identities
            ident_names = []
            try:
                ident_names = identity_ops.list_identity_names()
            except Exception:
                pass
            yield Static("\n[bold]Identities[/]", classes="section-title")
            if ident_names:
                yield Static(f"  Found: {', '.join(ident_names)}", classes="required-list")
            else:
                yield Static("  (none yet)", classes="hint")
            yield Button("Create new identity", id="btn-create-ident", variant="primary")
            for n in ident_names:
                yield Button(f"Edit: {n}", id=f"btn-edit-{_safe_id(n)}", name=n)

            # MCP secrets
            yield Static("\n[bold]Claude Code MCP Secrets[/]", classes="section-title")
            try:
                vals = identity_ops.read_mcp_secrets()
                set_count = sum(1 for v in vals.values() if v)
                total     = len(identity_ops.MCP_SECRETS_FIELDS)
                yield Static(f"  {set_count}/{total} fields set", classes="hint")
            except Exception:
                yield Static("  (could not read)", classes="hint")
            yield Button("Manage MCP secrets", id="btn-mcp", variant="primary")

            # Claude Code global instructions (CLAUDE.md content in BW notes).
            yield Static("\n[bold]Claude Code global instructions[/]", classes="section-title")
            try:
                _md = identity_ops.read_claude_md()
                _state = f"  {len(_md)} chars stored" if _md else "  (empty)"
            except Exception:
                _state = "  (could not read)"
            yield Static(_state, classes="hint")
            yield Button("Edit Claude Code global instructions", id="btn-claude-md", variant="primary")

            yield Static("")
            yield Button("Done — back to picker", id="btn-done")
        yield Footer()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "btn-create-ident":
            self.app.push_screen(IdentityFormScreen(mode="create"))
        elif bid.startswith("btn-edit-"):
            self.app.push_screen(IdentityFormScreen(mode="edit", name=event.button.name))
        elif bid == "btn-mcp":
            self.app.push_screen(McpSecretsFormScreen())
        elif bid == "btn-claude-md":
            self.app.push_screen(ClaudeConfigEditorScreen())
        elif bid == "btn-done":
            self.app.pop_screen()

    def action_back(self) -> None:
        self.app.pop_screen()


class IdentityFormScreen(Screen):
    """Create or edit a Machine Identity: <name> item. Handles SSH key
    options: generate ed25519, import from disk, paste text, or leave alone
    on edit."""
    BINDINGS = [
        Binding("ctrl+s", "save", "Save"),
        Binding("escape", "cancel", "Cancel"),
    ]

    def __init__(self, mode: str = "create", name: str | None = None):
        super().__init__()
        self.mode = mode
        self._initial_name = name
        self._loaded: dict = {}
        self._priv: str = ""
        self._pub: str = ""

    def on_mount(self) -> None:
        if self.mode == "edit" and self._initial_name:
            existing = identity_ops.read_identity(self._initial_name) or {}
            self._loaded = existing
            self._priv = existing.get("private_key", "")
            self._pub  = existing.get("public_key", "")
            # Hydrate inputs
            self.query_one("#name",  Input).value = existing.get("name", self._initial_name)
            self.query_one("#name",  Input).disabled = True   # name is the key; renaming = new item
            self.query_one("#gname", Input).value = existing.get("git_name", "")
            self.query_one("#gemail",Input).value = existing.get("git_email", "")
            applies = (existing.get("applies_to") or [{}])[0]
            self.query_one("#host",  Input).value = applies.get("host", "")
            helper = applies.get("credential_helper", "ssh") or "ssh"
            for v, _label in HELPER_OPTIONS:
                if v == helper:
                    rb = self.query_one(f"#h-{v}", RadioButton)
                    rb.value = True
                    break
            self.query_one("#default", RadioButton).value = bool(existing.get("default"))
            self._update_key_status()

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            title = "Edit identity" if self.mode == "edit" else "Create identity"
            yield Static(title, classes="step")
            yield Static(
                "Field meaning + how each value is used is in README → 'Adding a new identity'.\n"
                "Ctrl+S saves, Escape cancels.",
                classes="hint",
            )
            yield Static("name (slug, [A-Za-z0-9_-])", classes="cfg-title")
            yield Input(placeholder="personal", id="name")
            yield Static("git_name", classes="cfg-title")
            yield Input(placeholder="Your Name", id="gname")
            yield Static("git_email", classes="cfg-title")
            yield Input(placeholder="you@example.com", id="gemail")
            yield Static("host (e.g. github.com / bitbucket.org) — optional", classes="cfg-title")
            yield Input(placeholder="github.com", id="host")
            yield Static("credential_helper for that host", classes="cfg-title")
            buttons = [RadioButton(label, name=v, id=f"h-{v}", value=(v == "ssh"))
                       for v, label in HELPER_OPTIONS]
            yield RadioSet(*buttons, id="helper")
            yield RadioButton("Make this the default identity (global git config)",
                              id="default")

            yield Static("\nSSH key", classes="section-title")
            yield Static(id="key-status", classes="hint")
            yield Button("Generate new ed25519 key (replaces any existing)", id="btn-gen-key")
            yield Button("Import key files (paths to private + public)...",   id="btn-import-files")
            yield Button("Paste key text...",                                  id="btn-paste-key")
        yield Footer()

    def _update_key_status(self) -> None:
        status = self.query_one("#key-status", Static)
        if self._priv and self._pub:
            kind = "loaded from BW" if self.mode == "edit" else "set"
            status.update(f"[green]✓ SSH key {kind}[/]")
        elif self._priv or self._pub:
            status.update("[yellow]partial — need both private and public[/]")
        else:
            status.update("[dim]no SSH key yet — pick one of the actions below[/]")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        bid = event.button.id or ""
        if bid == "btn-gen-key":
            try:
                priv, pub = identity_ops._gen_ed25519_keypair(
                    comment=self.query_one("#gemail", Input).value or self.query_one("#name", Input).value
                )
                self._priv = priv
                self._pub  = pub
                self._update_key_status()
            except Exception as e:
                self.query_one("#key-status", Static).update(f"[red]ssh-keygen failed: {e}[/]")
        elif bid == "btn-import-files":
            self.app.push_screen(SshKeyFilesScreen(self))
        elif bid == "btn-paste-key":
            self.app.push_screen(SshKeyPasteScreen(self))

    def set_keys(self, priv: str, pub: str) -> None:
        self._priv = priv
        self._pub  = pub
        self._update_key_status()

    def action_save(self) -> None:
        name   = (self.query_one("#name", Input).value or "").strip()
        gname  = (self.query_one("#gname", Input).value or "").strip()
        gemail = (self.query_one("#gemail", Input).value or "").strip()
        host   = (self.query_one("#host", Input).value or "").strip()
        is_def = self.query_one("#default", RadioButton).value

        if not re.fullmatch(r"[A-Za-z0-9_-]+", name):
            self.query_one("#key-status", Static).update("[red]name must be alphanumeric / -_ [/]")
            return

        helper = "ssh"
        for v, _label in HELPER_OPTIONS:
            if self.query_one(f"#h-{v}", RadioButton).value:
                helper = v
                break

        applies_to: list[dict] = []
        if host:
            applies_to.append({
                "host": host,
                "git_url_patterns": [f"git@{host}:*/*", f"https://{host}/*/*"],
                "credential_helper": helper,
            })

        ok = identity_ops.upsert_identity(
            name,
            git_name=gname,
            git_email=gemail,
            is_default=bool(is_def),
            applies_to=applies_to,
            private_key=self._priv,
            public_key=self._pub,
        )
        if not ok:
            self.query_one("#key-status", Static).update("[red]save failed — see terminal log[/]")
            return
        _refresh_app_identities(self.app)
        self.app.pop_screen()

    def action_cancel(self) -> None:
        self.app.pop_screen()


class SshKeyFilesScreen(Screen):
    """Sub-screen: read SSH key from two file paths."""
    BINDINGS = [
        Binding("ctrl+s", "load", "Load"),
        Binding("escape", "back", "Cancel"),
    ]

    def __init__(self, parent_form: IdentityFormScreen):
        super().__init__()
        self.parent_form = parent_form

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Import SSH key from disk", classes="step")
            yield Static(
                "Paths to existing OpenSSH key files. Common defaults:\n"
                "  ~/.ssh/id_ed25519       (private)\n"
                "  ~/.ssh/id_ed25519.pub   (public)",
                classes="hint",
            )
            yield Static("Private key path", classes="cfg-title")
            yield Input(placeholder=str(Path.home() / ".ssh/id_ed25519"), id="priv-path")
            yield Static("Public key path", classes="cfg-title")
            yield Input(placeholder=str(Path.home() / ".ssh/id_ed25519.pub"), id="pub-path")
            yield Static(id="files-status", classes="hint")
            yield Button("Load (Ctrl+S)", id="btn-load")
        yield Footer()

    def action_load(self) -> None:
        priv_p = (self.query_one("#priv-path", Input).value or "").strip()
        pub_p  = (self.query_one("#pub-path",  Input).value or "").strip()
        if not priv_p or not pub_p:
            self.query_one("#files-status", Static).update("[red]both paths required[/]")
            return
        try:
            priv = Path(priv_p).expanduser().read_text()
            pub  = Path(pub_p).expanduser().read_text()
        except Exception as e:
            self.query_one("#files-status", Static).update(f"[red]read failed: {e}[/]")
            return
        self.parent_form.set_keys(priv, pub)
        self.app.pop_screen()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-load":
            self.action_load()

    def action_back(self) -> None:
        self.app.pop_screen()


class SshKeyPasteScreen(Screen):
    """Sub-screen: paste private/public key text directly."""
    BINDINGS = [
        Binding("ctrl+s", "load", "Load"),
        Binding("escape", "back", "Cancel"),
    ]

    def __init__(self, parent_form: IdentityFormScreen):
        super().__init__()
        self.parent_form = parent_form

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Paste SSH key text", classes="step")
            yield Static(
                "Paste each on a single line (Input widgets are line-oriented).\n"
                "For multi-line keys use the 'Import key files' option.\n"
                "Or paste base64-only blob for the body and we'll wrap it.",
                classes="hint",
            )
            yield Static("Private key (full -----BEGIN ... END----- block)", classes="cfg-title")
            yield Input(password=True, placeholder="-----BEGIN OPENSSH PRIVATE KEY-----...-----END...-----", id="priv-text")
            yield Static("Public key (single ssh-ed25519/rsa/... line)", classes="cfg-title")
            yield Input(placeholder="ssh-ed25519 AAAA... comment", id="pub-text")
            yield Static(id="paste-status", classes="hint")
            yield Button("Load (Ctrl+S)", id="btn-load")
        yield Footer()

    def action_load(self) -> None:
        priv = (self.query_one("#priv-text", Input).value or "").strip()
        pub  = (self.query_one("#pub-text",  Input).value or "").strip()
        if not priv or not pub:
            self.query_one("#paste-status", Static).update("[red]both fields required[/]")
            return
        # Auto-wrap if user pasted only the base64 body
        if not priv.startswith("-----BEGIN"):
            priv = "-----BEGIN OPENSSH PRIVATE KEY-----\n" + priv + "\n-----END OPENSSH PRIVATE KEY-----"
        self.parent_form.set_keys(priv, pub)
        self.app.pop_screen()

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-load":
            self.action_load()

    def action_back(self) -> None:
        self.app.pop_screen()


class McpSecretsFormScreen(Screen):
    """Edit the Claude Code MCP Secrets BW item (creates if missing).
    All fields shown together — Ctrl+S saves them all atomically."""
    BINDINGS = [
        Binding("ctrl+s", "save", "Save"),
        Binding("escape", "back", "Cancel"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Claude Code MCP Secrets", classes="step")
            yield Static(
                "Field values used by the chezmoi MCP-register script. Hidden\n"
                "fields are stored as 'hidden' type in BW. Empty values overwrite\n"
                "(deterministic). Ctrl+S to save.",
                classes="hint",
            )
            try:
                current = identity_ops.read_mcp_secrets()
            except Exception as e:
                yield Static(f"[red]could not read existing values: {e}[/]")
                current = {}
            for fname, hidden, label, placeholder in identity_ops.MCP_SECRETS_FIELDS:
                yield Static(f"{label}  ([dim]{fname}[/])", classes="cfg-title")
                yield Input(
                    value=current.get(fname, "") or "",
                    password=hidden,
                    placeholder=placeholder,
                    id=f"f-{_safe_id(fname)}",
                )
            yield Static(id="mcp-status", classes="hint")
            yield Button("Save (Ctrl+S)", id="btn-mcp-save")
        yield Footer()

    def action_save(self) -> None:
        values = {}
        for fname, _hidden, _label, _placeholder in identity_ops.MCP_SECRETS_FIELDS:
            values[fname] = (self.query_one(f"#f-{_safe_id(fname)}", Input).value or "").strip()
        ok = identity_ops.write_mcp_secrets(values)
        status = self.query_one("#mcp-status", Static)
        if ok:
            status.update("[green]saved[/]")
            # auto-pop after a short pause is hard without timers; just pop now
            self.app.pop_screen()
        else:
            status.update("[red]save failed — see terminal log[/]")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-mcp-save":
            self.action_save()

    def action_back(self) -> None:
        self.app.pop_screen()


class ClaudeConfigEditorScreen(Screen):
    """Edit the Claude Code Global Config BW item's notes field, which holds
    the contents of ~/.claude/CLAUDE.md. Bitwarden is the source of truth;
    the chezmoi component writes the file back out at apply time."""
    BINDINGS = [
        Binding("ctrl+s", "save", "Save"),
        Binding("escape", "back", "Cancel"),
    ]

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Claude Code global instructions", classes="step")
            yield Static(
                "Contents of ~/.claude/CLAUDE.md. Stored in Bitwarden as the\n"
                "notes field of 'Claude Code Global Config'. Ctrl+S to save,\n"
                "Esc to cancel.",
                classes="hint",
            )
            yield TextArea(id="claude-md-area", show_line_numbers=False)
            yield Static(id="claude-md-status", classes="status")
            yield Button("Save (Ctrl+S)", id="btn-claude-md-save", variant="primary")
        yield Footer()

    def on_mount(self) -> None:
        self.query_one("#claude-md-status", Static).update("Loading from Bitwarden...")
        self.run_worker(self._do_load(), thread=True, exclusive=True)

    async def _do_load(self) -> None:
        content = ""
        try:
            content = identity_ops.read_claude_md()
        except Exception as e:
            self.app.call_from_thread(
                self.query_one("#claude-md-status", Static).update,
                f"[red]load failed: {e}[/]",
            )
            return
        ta = self.query_one("#claude-md-area", TextArea)
        self.app.call_from_thread(ta.load_text, content)
        self.app.call_from_thread(self.query_one("#claude-md-status", Static).update, "")
        self.app.call_from_thread(ta.focus)

    def action_save(self) -> None:
        ta = self.query_one("#claude-md-area", TextArea)
        content = ta.text
        self.query_one("#claude-md-status", Static).update("Writing to Bitwarden...")
        self.run_worker(self._do_save(content), thread=True, exclusive=True)

    async def _do_save(self, content: str) -> None:
        ok = identity_ops.write_claude_md(content)
        status = self.query_one("#claude-md-status", Static)
        if ok:
            self.app.call_from_thread(status.update, "[green]saved[/]")
            self.app.call_from_thread(self.app.pop_screen)
        else:
            self.app.call_from_thread(status.update, "[red]save failed — see terminal log[/]")

    def on_button_pressed(self, event: Button.Pressed) -> None:
        if event.button.id == "btn-claude-md-save":
            self.action_save()

    def action_back(self) -> None:
        self.app.pop_screen()


# ── App ─────────────────────────────────────────────────────────────────────

CSS = """
Screen { padding: 1 2; }
.step { background: $accent; color: $text; padding: 0 1; margin-bottom: 1; }
.hint { color: $text-muted; margin-bottom: 1; }
.section-title { text-style: bold; margin-top: 1; }
.required-list { color: $success; }
.auth-title { margin-top: 1; }
.cfg-title { margin-top: 1; }
.status { color: $warning; margin-top: 1; }
SelectionList { height: auto; max-height: 18; border: round $primary; }
RadioSet { height: auto; }
Input { margin-bottom: 1; }
"""


class BootstrapApp(App):
    """All-in-one TUI: unlock → discover → identity → auth → components → config."""
    CSS = CSS
    TITLE = "machine-setup"

    def __init__(self, initial_state: dict, registry_file: Path, os_tag: str):
        super().__init__()
        self.state = dict(initial_state)
        self.registry_file = registry_file
        self.os_tag = os_tag
        # Filled in by DiscoveryScreen
        self.available_idents: list[dict] = []
        self.all_components: list[dict] = []

    # ── Initial flow ───────────────────────────────────────────────────────

    def on_mount(self) -> None:
        if bw.is_unlocked():
            # Already unlocked (BW_SESSION in env); skip straight to discovery
            self.push_screen(DiscoveryScreen())
        elif bw.have_bw():
            self.push_screen(UnlockScreen())
        else:
            # No bw CLI — proceed with whatever's locally available (TOML only)
            self.push_screen(DiscoveryScreen())

    def advance_after_unlock(self) -> None:
        self.pop_screen()
        self.push_screen(DiscoveryScreen())

    def advance_to_identity(self) -> None:
        self.pop_screen()
        self.push_screen(IdentityScreen(self.available_idents, self.state.get("identities") or []))

    def advance_to_auth(self) -> None:
        # Build auth pairs from current identity selection
        existing = self.state.get("identity_overrides") or {}
        pairs: list[dict] = []
        for name in (self.state.get("identities") or []):
            try:
                ident = config.load_identity(name)
            except FileNotFoundError:
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
        self.pop_screen()
        self.push_screen(AuthScreen(pairs, existing))

    def advance_to_components(self) -> None:
        required = config._required_components(self.state.get("identities") or [], self.os_tag)
        optional = [c for c in self.all_components if c["name"] not in set(required)]
        self.pop_screen()
        self.push_screen(ComponentScreen(
            required, optional,
            self.state.get("extra_components") or [],
            self.state.get("identities") or [],
            self.os_tag,
        ))

    def advance_to_config(self) -> None:
        plan = driver.build_plan(
            identities=self.state.get("identities") or [],
            extra_components=self.state.get("extra_components") or [],
            identity_overrides=self.state.get("identity_overrides") or {},
            component_config=self.state.get("component_config") or {},
            os_tag=self.os_tag,
        )
        names = [c["name"] for c in plan["components"]]
        self.pop_screen()
        self.push_screen(ConfigScreen(names, self.state.get("component_config") or {}))

    def advance_to_sudo(self) -> None:
        # Skip on Windows + when running as root + when sudo is already cached.
        skip = False
        if sys.platform == "win32":
            skip = True
        elif hasattr(os, "geteuid") and os.geteuid() == 0:
            skip = True
        else:
            import subprocess as sp
            try:
                rc = sp.call(["sudo", "-n", "-v"], stdout=sp.DEVNULL, stderr=sp.DEVNULL)
                if rc == 0:
                    skip = True
                    self.state["_sudo_cached"] = True
            except FileNotFoundError:
                skip = True
        if skip:
            self.advance_to_run()
            return
        self.pop_screen()
        self.push_screen(SudoScreen())

    def advance_to_run(self) -> None:
        """Persist machine.toml + start the in-TUI plan run."""
        # Sync BW one more time before plan execution so any item-field
        # changes you made between entering the password and confirming the
        # last picker are visible to component scripts (e.g. mcp-bitbucket
        # reading new BW fields).
        if bw.is_unlocked():
            bw.sync()
        # Persist state before running so the user keeps their selections
        # even if a component fails / they kill the run.
        try:
            from machine_config import _emit_toml as _toml_emit  # noqa: F401
        except ImportError:
            pass
        # Save via subprocess (machine_config.py CLI) — same path main.py uses
        import subprocess
        config_dir = Path(os.environ.get("XDG_CONFIG_HOME") or (Path.home() / ".config")) / "machine-setup"
        config_dir.mkdir(parents=True, exist_ok=True)
        config_file = config_dir / "machine.toml"
        payload = json.dumps({
            "identities":         self.state.get("identities") or [],
            "extra_components":   self.state.get("extra_components") or [],
            "identity_overrides": self.state.get("identity_overrides") or {},
            "component_config":   self.state.get("component_config") or {},
        })
        subprocess.run(
            [sys.executable, str(Path(__file__).parent / "machine_config.py"), "dump", str(config_file)],
            input=payload, text=True,
        )

        # Build the actual plan
        plan = driver.build_plan(
            identities=self.state.get("identities") or [],
            extra_components=self.state.get("extra_components") or [],
            identity_overrides=self.state.get("identity_overrides") or {},
            component_config=self.state.get("component_config") or {},
            os_tag=self.os_tag,
        )
        machine_setup_dir = Path(__file__).resolve().parent.parent
        # Pop whatever's currently on top (ConfigScreen or SudoScreen)
        self.pop_screen()
        self.push_screen(RunPlanScreen(plan, machine_setup_dir))


# ── Entrypoint ──────────────────────────────────────────────────────────────

def run_app(initial_state: dict, registry_file: Path, os_tag: str) -> dict:
    app = BootstrapApp(initial_state=initial_state, registry_file=registry_file, os_tag=os_tag)
    result = app.run()
    if result is None:
        return {"action": "abort", "state": initial_state}
    return result
