#!/usr/bin/env bash
# First-run profile + component pickers. Persist choices to
# ~/.config/machine-setup/machine.toml so subsequent runs are non-interactive.
#
# Caller must have sourced lib/common.sh and set MACHINE_SETUP_DIR.

MACHINE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/machine-setup"
MACHINE_CONFIG_FILE="$MACHINE_CONFIG_DIR/machine.toml"

# ── Profile picker ──────────────────────────────────────────────────────────

# Pick a profile interactively. Sets PROFILE.
# Order: $MACHINE_SETUP_PROFILE → saved machine.toml → TUI prompt.
ui_pick_profile() {
  if [ -n "${MACHINE_SETUP_PROFILE:-}" ]; then
    PROFILE="$MACHINE_SETUP_PROFILE"
    log "Using profile from MACHINE_SETUP_PROFILE: $PROFILE"
    return 0
  fi

  if [ -f "$MACHINE_CONFIG_FILE" ]; then
    local saved
    saved=$(_machine_config_read profile)
    if [ -n "$saved" ]; then
      PROFILE="$saved"
      log "Using saved profile: $PROFILE  ($MACHINE_CONFIG_FILE)"
      return 0
    fi
  fi

  _ui_prompt_profile || die "No profile selected"
  _machine_config_write profile "$PROFILE"
  log "Saved profile selection to $MACHINE_CONFIG_FILE"
}

ui_pick_profile_force() {
  unset MACHINE_SETUP_PROFILE
  rm -f "$MACHINE_CONFIG_FILE"
  ui_pick_profile
}

_ui_prompt_profile() {
  local profiles_json
  profiles_json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" list-profiles) \
    || die "Failed to list profiles"

  if [ -z "$profiles_json" ]; then
    die "No profiles found. Add at least one to profiles/ or local/profiles/."
  fi

  local names=() labels=()
  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local n d s
    n=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['name'])")
    d=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('description',''))")
    s=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['source'])")
    names+=("$n")
    if [ -n "$d" ]; then
      labels+=("$n — $d  [$s]")
    else
      labels+=("$n  [$s]")
    fi
  done <<< "$profiles_json"

  if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
    _ui_whiptail_radio_profile names labels
  else
    _ui_select_fallback_profile names labels
  fi
}

_ui_whiptail_radio_profile() {
  local -n _names=$1 _labels=$2
  local args=()
  for i in "${!_names[@]}"; do
    args+=("${_names[$i]}" "${_labels[$i]}")
  done
  PROFILE=$(whiptail \
    --title "machine-setup" \
    --menu "Pick a profile for this machine:" \
    20 78 10 \
    "${args[@]}" \
    3>&1 1>&2 2>&3) || return 1
}

_ui_select_fallback_profile() {
  local -n _names=$1 _labels=$2
  echo ""
  echo "Pick a profile for this machine:"
  echo ""
  local i=1
  for label in "${_labels[@]}"; do
    printf "  %d) %s\n" "$i" "$label"
    i=$((i + 1))
  done
  echo ""
  while :; do
    read -r -p "Enter number (1-${#_names[@]}): " choice
    if [[ "$choice" =~ ^[0-9]+$ ]] && [ "$choice" -ge 1 ] && [ "$choice" -le "${#_names[@]}" ]; then
      PROFILE="${_names[$((choice - 1))]}"
      return 0
    fi
    echo "Invalid choice."
  done
}

# ── Component picker ────────────────────────────────────────────────────────

# Sets COMPONENTS_OVERRIDE — comma-separated list of selected component names.
# Order: $MACHINE_SETUP_COMPONENTS → saved machine.toml `components` → TUI.
# If --quiet was passed (QUIET_MODE=1), skips the picker and uses the profile's
# components as-is (no override).
ui_pick_components() {
  if [ -n "${MACHINE_SETUP_COMPONENTS:-}" ]; then
    COMPONENTS_OVERRIDE="$MACHINE_SETUP_COMPONENTS"
    log "Using components from MACHINE_SETUP_COMPONENTS"
    return 0
  fi

  local saved
  saved=$(_machine_config_read components)
  if [ -n "$saved" ]; then
    COMPONENTS_OVERRIDE="$saved"
    log "Using saved component selection ($MACHINE_CONFIG_FILE)"
    return 0
  fi

  if [ "${QUIET_MODE:-0}" = "1" ]; then
    log "Quiet mode: using profile's component list as-is."
    COMPONENTS_OVERRIDE=""
    return 0
  fi

  _ui_prompt_components || { warn "Picker cancelled — using profile defaults"; COMPONENTS_OVERRIDE=""; return 0; }
  _machine_config_write components "$COMPONENTS_OVERRIDE"
  log "Saved component selection to $MACHINE_CONFIG_FILE"
}

ui_pick_components_force() {
  unset MACHINE_SETUP_COMPONENTS
  _machine_config_unset components
  ui_pick_components
}

_ui_prompt_components() {
  local os_tag json names=() descs=() defaults=()
  os_tag="${MACHINE_SETUP_OS_TAG:-$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)}"
  json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" list-components \
           --profile "$PROFILE" --os-tag "$os_tag") \
    || { warn "Failed to list components"; return 1; }

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    names+=("$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['name'])")")
    descs+=("$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('description',''))")")
    defaults+=("$(printf '%s' "$line" | python3 -c "import sys,json; print('1' if json.loads(sys.stdin.read()).get('in_profile') else '0')")")
  done <<< "$json"

  if [ "${#names[@]}" -eq 0 ]; then
    warn "No components found for OS tag '$os_tag'"
    return 1
  fi

  if command -v whiptail >/dev/null 2>&1 && [ -t 0 ]; then
    _ui_whiptail_checklist names descs defaults
  else
    _ui_toggle_fallback names descs defaults
  fi
}

_ui_whiptail_checklist() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local args=()
  for i in "${!_names[@]}"; do
    local on="OFF"
    [ "${_defaults[$i]}" = "1" ] && on="ON"
    # Truncate description to keep the box readable (~50 chars width)
    local d="${_descs[$i]}"
    [ "${#d}" -gt 50 ] && d="${d:0:47}..."
    args+=("${_names[$i]}" "$d" "$on")
  done
  local picked
  picked=$(whiptail \
    --title "machine-setup — components for profile '$PROFILE'" \
    --checklist "Toggle components with SPACE; ENTER to confirm.\nDeps are auto-pulled in by the resolver." \
    22 80 14 \
    "${args[@]}" \
    3>&1 1>&2 2>&3) || return 1
  # whiptail emits names quoted ("a" "b" "c"); convert to comma-separated
  COMPONENTS_OVERRIDE=$(printf '%s' "$picked" | sed 's/"//g' | tr ' ' ',')
}

_ui_toggle_fallback() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local -a sel=("${_defaults[@]}")  # copy

  while :; do
    echo ""
    echo "Components — toggle with numbers (e.g. 3 5 7), or ENTER to confirm:"
    echo ""
    local i
    for i in "${!_names[@]}"; do
      local mark="[ ]"
      [ "${sel[$i]}" = "1" ] && mark="[x]"
      printf "  %2d) %s %-25s %s\n" "$((i+1))" "$mark" "${_names[$i]}" "${_descs[$i]}"
    done
    echo ""
    read -r -p "> " input
    [ -z "$input" ] && break
    for tok in $input; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#_names[@]}" ]; then
        local idx=$((tok - 1))
        if [ "${sel[$idx]}" = "1" ]; then sel[$idx]=0; else sel[$idx]=1; fi
      else
        echo "  ignored: $tok"
      fi
    done
  done

  local out=()
  for i in "${!_names[@]}"; do
    [ "${sel[$i]}" = "1" ] && out+=("${_names[$i]}")
  done
  COMPONENTS_OVERRIDE=$(IFS=,; printf '%s' "${out[*]}")
}

# ── machine.toml read/write ─────────────────────────────────────────────────

_machine_config_read() {
  local key="$1"
  [ -f "$MACHINE_CONFIG_FILE" ] || return 0
  python3 - "$MACHINE_CONFIG_FILE" "$key" <<'PY'
import sys, tomllib
path, key = sys.argv[1], sys.argv[2]
try:
    with open(path, 'rb') as f:
        data = tomllib.load(f)
    val = data.get(key)
    if isinstance(val, list):
        print(",".join(val))
    elif val is not None:
        print(val)
except Exception:
    pass
PY
}

# Write a single key. Handles string and comma-separated-list values:
#   _machine_config_write profile work-desktop
#   _machine_config_write components "packages,nvm,claude-code"
_machine_config_write() {
  local key="$1" value="$2"
  mkdir -p "$MACHINE_CONFIG_DIR"
  python3 - "$MACHINE_CONFIG_FILE" "$key" "$value" <<'PY'
import sys, tomllib, pathlib
path, key, value = sys.argv[1], sys.argv[2], sys.argv[3]
p = pathlib.Path(path)
data = {}
if p.exists():
    try:
        data = tomllib.loads(p.read_text())
    except Exception:
        data = {}

if "," in value:
    data[key] = [v.strip() for v in value.split(",") if v.strip()]
else:
    data[key] = value

# Hand-write TOML (no stdlib writer in 3.11). We only emit string/list[string].
out = ["# Auto-generated by machine-setup. Edit to switch settings, or delete this",
       "# file to be re-prompted on next bootstrap run.", ""]
for k, v in data.items():
    if isinstance(v, list):
        items = ", ".join('"{}"'.format(x.replace('"', '\\"')) for x in v)
        out.append(f'{k} = [{items}]')
    else:
        out.append(f'{k} = "{v}"')
p.write_text("\n".join(out) + "\n")
PY
}

_machine_config_unset() {
  local key="$1"
  [ -f "$MACHINE_CONFIG_FILE" ] || return 0
  python3 - "$MACHINE_CONFIG_FILE" "$key" <<'PY'
import sys, tomllib, pathlib
path, key = sys.argv[1], sys.argv[2]
p = pathlib.Path(path)
try:
    data = tomllib.loads(p.read_text())
except Exception:
    sys.exit(0)
data.pop(key, None)
out = ["# Auto-generated by machine-setup. Edit to switch settings, or delete this",
       "# file to be re-prompted on next bootstrap run.", ""]
for k, v in data.items():
    if isinstance(v, list):
        items = ", ".join('"{}"'.format(x.replace('"', '\\"')) for x in v)
        out.append(f'{k} = [{items}]')
    else:
        out.append(f'{k} = "{v}"')
p.write_text("\n".join(out) + "\n")
PY
}
