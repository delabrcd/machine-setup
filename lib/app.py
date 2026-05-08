#!/usr/bin/env python3
"""Full-screen Textual TUI for the picker phase.

main.py prefers this when Textual + a TTY are available, falling back to
the questionary path in lib/tui.py otherwise.

Flow:
    Step 1/4  — Identity selection      (checkbox list + [+] create new)
    Step 2/4  — Per-identity auth       (radio per identity-host)
    Step 3/4  — Component selection     (required header + optional checkboxes)
    Step 4/4  — Component configuration (text inputs for chezmoi.repo etc.)

After the last step, the app exits and returns the final state dict to
main.py which then runs sudo -v + the plan in the plain terminal.

Component output during plan execution is intentionally NOT inside the
Textual app — sudo + apt/dnf/winget output is more useful seen directly,
and capturing it would conflict with sudo's TTY-locking password prompt.
"""
from __future__ import annotations
from typing import Optional
import sys

from textual.app import App, ComposeResult
from textual.binding import Binding
from textual.containers import Vertical, Horizontal, VerticalScroll
from textual.screen import Screen
from textual.widgets import (
    Footer, Header, Input, Label, RadioButton, RadioSet,
    SelectionList, Static, Button,
)
from textual.widgets.selection_list import Selection


_NEW_IDENT_TAG = "__create_new_identity__"


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
                "Use space to toggle, Ctrl+S to continue.",
                classes="hint",
            )
            options = [Selection(
                f"[+] Create new identity in Bitwarden...",
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
            self.app.exit({"action": "create_identity"})
            return
        self.app.state["identities"] = picked
        self.app.action_next_step()

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
            yield Static(
                "Choose a credential helper for each identity-host pair.\n"
                "Tab between groups, arrows to choose, Ctrl+S to continue.",
                classes="hint",
            )
            for pair in self.pairs:
                ident, host, default = pair["identity"], pair["host"], pair.get("current_helper") or "ssh"
                yield Static(f"\n[bold]{ident}[/] on [bold]{host}[/]", classes="auth-title")
                rb = RadioSet(id=f"rs-{ident}-{host}")
                for value, label in HELPER_OPTIONS:
                    btn = RadioButton(label, value=(value == default), id=f"rb-{ident}-{host}-{value}", name=value)
                    rb.compose_add_child(btn)
                yield rb
        yield Footer()

    def action_advance(self) -> None:
        out = dict(self.current)
        for pair in self.pairs:
            ident, host = pair["identity"], pair["host"]
            rs: RadioSet = self.query_one(f"#rs-{ident}-{host}", RadioSet)
            pressed = rs.pressed_button
            value = pressed.name if pressed else (pair.get("current_helper") or "ssh")
            out.setdefault(ident, {}).setdefault(host, {})["credential_helper"] = value
        self.app.state["identity_overrides"] = out
        self.app.action_next_step()

    def action_back(self) -> None:
        self.app.action_prev_step()


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
            yield Static("  " + ", ".join(self.required) if self.required else "  (none)", classes="required-list")
            yield Static("\nOptional:", classes="section-title")
            options = [
                Selection(
                    f"{c['name']:<22} {c.get('description','')[:60]}",
                    c["name"],
                    c["name"] in self._initial,
                )
                for c in self.optional
            ]
            yield SelectionList[str](*options, id="comp-list")
        yield Footer()

    def action_advance(self) -> None:
        sl: SelectionList = self.query_one("#comp-list", SelectionList)
        self.app.state["extra_components"] = list(sl.selected)
        self.app.action_next_step()

    def action_back(self) -> None:
        self.app.action_prev_step()


# ── Config screen ───────────────────────────────────────────────────────────

CONFIG_SCHEMA: dict[str, list[tuple[str, str, Optional[str]]]] = {
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
        self.current = dict(current_config)
        self._needed: list[tuple[str, str, str, Optional[str]]] = []  # (comp, field, label, default)
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
                yield Static("No selected component needs additional config. Ctrl+S to continue.", classes="hint")
            else:
                yield Static(
                    "Fill in any missing values. Tab between fields. Ctrl+S to finish.",
                    classes="hint",
                )
                for comp, field, label, default in self._needed:
                    existing = (self.current.get(comp) or {}).get(field, "")
                    initial = existing or (default or "")
                    yield Static(f"\n[bold]{comp}.{field}[/]  — {label}", classes="cfg-title")
                    yield Input(value=initial, placeholder=default or "", id=f"in-{comp}-{field}")
        yield Footer()

    def action_advance(self) -> None:
        out = {k: dict(v) for k, v in self.current.items()}
        for comp, field, _label, default in self._needed:
            inp: Input = self.query_one(f"#in-{comp}-{field}", Input)
            val = (inp.value or "").strip()
            if not val and default:
                val = default
            if val:
                out.setdefault(comp, {})[field] = val
        self.app.state["component_config"] = out
        self.app.exit({"action": "done", "state": self.app.state})

    def action_back(self) -> None:
        self.app.action_prev_step()


# ── App ─────────────────────────────────────────────────────────────────────

CSS = """
Screen { padding: 1 2; }
.step { background: $accent; color: $text; padding: 0 1; margin-bottom: 1; }
.hint { color: $text-muted; margin-bottom: 1; }
.section-title { text-style: bold; margin-top: 1; }
.required-list { color: $success; }
.auth-title { margin-top: 1; }
.cfg-title { margin-top: 1; }
SelectionList { height: auto; max-height: 18; border: round $primary; }
RadioSet { height: auto; }
Input { margin-bottom: 1; }
"""


class BootstrapApp(App):
    """Drives the four picker screens. State accumulates in self.state.

    Inputs (constructor):
        initial_state    — current values of identities / extra_components /
                           identity_overrides / component_config (dict)
        available_idents — list of identity dicts (from list_known_identities)
        os_tag           — OS tag string for filtering components
        all_components   — list of all component dicts available on this OS
        required         — list of component names auto-pulled-in by identities
        plan_components  — current list of plan component names (for cfg screen)
        auth_pairs       — list of (identity, host, current_helper) dicts
    """
    CSS = CSS
    TITLE = "machine-setup"

    def __init__(
        self,
        initial_state: dict,
        available_idents: list[dict],
        all_components: list[dict],
        required: list[str],
        plan_components: list[str],
        auth_pairs: list[dict],
    ):
        super().__init__()
        self.state = dict(initial_state)
        self.available_idents = available_idents
        self.all_components = all_components
        self.required = required
        self.plan_components = plan_components
        self.auth_pairs = auth_pairs
        self._step = 0

    def on_mount(self) -> None:
        self._step = 0
        self.push_screen(self._screen_for_step(0))

    # ── Step navigation ─────────────────────────────────────────────────────

    def _screen_for_step(self, idx: int) -> Screen:
        if idx == 0:
            return IdentityScreen(self.available_idents, self.state.get("identities") or [])
        if idx == 1:
            # Rebuild auth_pairs based on current identity selection — the user
            # may have changed it on screen 1.
            return AuthScreen(self.auth_pairs, self.state.get("identity_overrides") or {})
        if idx == 2:
            optional = [c for c in self.all_components if c["name"] not in set(self.required)]
            return ComponentScreen(self.required, optional, self.state.get("extra_components") or [])
        if idx == 3:
            return ConfigScreen(self.plan_components, self.state.get("component_config") or {})
        raise IndexError(f"no screen for step {idx}")

    def action_next_step(self) -> None:
        self._step += 1
        if self._step >= 4:
            self.exit({"action": "done", "state": self.state})
            return
        self.pop_screen()
        self.push_screen(self._screen_for_step(self._step))

    def action_prev_step(self) -> None:
        if self._step <= 0:
            return
        self._step -= 1
        self.pop_screen()
        self.push_screen(self._screen_for_step(self._step))


# ── Entrypoint helpers consumed by main.py ──────────────────────────────────

def run_app(
    initial_state: dict,
    available_idents: list[dict],
    all_components: list[dict],
    required: list[str],
    plan_components: list[str],
    auth_pairs: list[dict],
) -> dict:
    """Launch the app. Returns the final result dict:
        {"action": "done"|"create_identity"|"abort", "state": {...}}
    Caller (main.py) handles the create_identity loop by re-launching after
    creating the new BW item.
    """
    app = BootstrapApp(
        initial_state=initial_state,
        available_idents=available_idents,
        all_components=all_components,
        required=required,
        plan_components=plan_components,
        auth_pairs=auth_pairs,
    )
    result = app.run()
    if result is None:
        return {"action": "abort", "state": initial_state}
    return result
