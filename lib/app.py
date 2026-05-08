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
from textual.containers import VerticalScroll, Center
from textual.screen import Screen
from textual.widgets import (
    Footer, Header, Input, RadioButton, RadioSet,
    SelectionList, Static,
)
from textual.widgets.selection_list import Selection

# Local modules — sys.path was set up by main.py before launching us
import bw            # noqa: E402
import config        # noqa: E402
import driver        # noqa: E402
import identity_ops  # noqa: E402


_NEW_IDENT_TAG = "__create_new_identity__"


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
            options = [Selection(
                "[+] Create new identity in Bitwarden...",
                _NEW_IDENT_TAG,
                False,
            )]
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
        if _NEW_IDENT_TAG in picked:
            picked = [p for p in picked if p != _NEW_IDENT_TAG]
            self.app.state["identities"] = picked
            self.app.exit({"action": "create_identity", "state": self.app.state})
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

    def __init__(self, required: list[str], optional: list[dict], selected: list[str]):
        super().__init__()
        self.required = required
        self.optional = optional
        self._initial = set(selected)

    def compose(self) -> ComposeResult:
        yield Header(show_clock=False)
        with VerticalScroll():
            yield Static("Step 3 of 4 — Components", classes="step")
            yield Static(
                "Required components are auto-installed. Toggle optional ones below.\n"
                "Selecting an optional with deps (e.g. chezmoi → uv) auto-pulls them in.\n"
                "Space to toggle, Ctrl+S to continue.",
                classes="hint",
            )
            yield Static("Required (auto-installed):", classes="section-title")
            yield Static("  " + (", ".join(self.required) if self.required else "(none)"), classes="required-list")
            yield Static("\nOptional:", classes="section-title")
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
        yield Footer()

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
    "chezmoi": [
        ("repo", "Dotfiles repo URL (e.g. https://github.com/<you>/dotfiles.git)", None),
    ],
    "dev-utilities": [
        ("repo", "git URL of repo to clone", None),
        ("dest", "Destination path", "~/.local/share/dev-utilities"),
    ],
    "bitbucket-mcp": [
        ("path", "MCP source dir", "~/.local/share/dev-utilities/bitbucket-mcp"),
    ],
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
        self.app.exit({"action": "done", "state": self.app.state})

    def action_back(self) -> None:
        self.app.advance_to_components()


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
        self.push_screen(ComponentScreen(required, optional, self.state.get("extra_components") or []))

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


# ── Entrypoint ──────────────────────────────────────────────────────────────

def run_app(initial_state: dict, registry_file: Path, os_tag: str) -> dict:
    app = BootstrapApp(initial_state=initial_state, registry_file=registry_file, os_tag=os_tag)
    result = app.run()
    if result is None:
        return {"action": "abort", "state": initial_state}
    return result
