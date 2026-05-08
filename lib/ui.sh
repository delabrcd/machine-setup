#!/usr/bin/env bash
# Interactive pickers for the bootstrap. Profile-less model:
#   1. ui_pick_identities       — which identities to install on this machine
#   2. ui_pick_auth             — credential helper per identity-host
#   3. ui_pick_components       — required (info) + optional (toggleable)
#   4. ui_prompt_component_config — fill missing repo/path values for selected components
#
# State lives in shell vars (loaded from machine.toml at the top of bootstrap.sh,
# saved back via _machine_state_save) so all decisions persist between runs.
#
# Caller must have sourced lib/common.sh and set MACHINE_SETUP_DIR.

MACHINE_CONFIG_DIR="${XDG_CONFIG_HOME:-$HOME/.config}/machine-setup"
MACHINE_CONFIG_FILE="$MACHINE_CONFIG_DIR/machine.toml"

# ── machine.toml round-trip (delegated to lib/machine_config.py) ────────────

# Loads machine.toml into shell vars: IDENTITIES_OVERRIDE, EXTRA_COMPONENTS,
# IDENTITY_OVERRIDES_JSON, COMPONENT_CONFIG_JSON, and MACHINE_LEGACY_JSON
# (anything that didn't fit the schema — we use it for migration).
_machine_state_load() {
  local raw
  raw=$(python3 "$MACHINE_SETUP_DIR/lib/machine_config.py" load "$MACHINE_CONFIG_FILE")
  IDENTITIES_OVERRIDE=$(printf '%s' "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(','.join(d.get('identities') or []))
")
  EXTRA_COMPONENTS=$(printf '%s' "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(','.join(d.get('extra_components') or []))
")
  IDENTITY_OVERRIDES_JSON=$(printf '%s' "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('identity_overrides') or {}))
")
  COMPONENT_CONFIG_JSON=$(printf '%s' "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('component_config') or {}))
")
  MACHINE_LEGACY_JSON=$(printf '%s' "$raw" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(json.dumps(d.get('_legacy') or {}))
")
  export IDENTITIES_OVERRIDE EXTRA_COMPONENTS IDENTITY_OVERRIDES_JSON COMPONENT_CONFIG_JSON MACHINE_LEGACY_JSON
}

_machine_state_save() {
  python3 -c "
import json, os
print(json.dumps({
  'identities':         [n for n in os.environ.get('IDENTITIES_OVERRIDE','').split(',') if n],
  'extra_components':   [c for c in os.environ.get('EXTRA_COMPONENTS','').split(',') if c],
  'identity_overrides': json.loads(os.environ.get('IDENTITY_OVERRIDES_JSON','{}') or '{}'),
  'component_config':   json.loads(os.environ.get('COMPONENT_CONFIG_JSON','{}') or '{}'),
}))
" | python3 "$MACHINE_SETUP_DIR/lib/machine_config.py" dump "$MACHINE_CONFIG_FILE"
}

# Hard reset of saved choices for --reconfigure.
_machine_state_reset() {
  rm -f "$MACHINE_CONFIG_FILE"
  IDENTITIES_OVERRIDE="" EXTRA_COMPONENTS="" IDENTITY_OVERRIDES_JSON='{}' COMPONENT_CONFIG_JSON='{}' MACHINE_LEGACY_JSON='{}'
  export IDENTITIES_OVERRIDE EXTRA_COMPONENTS IDENTITY_OVERRIDES_JSON COMPONENT_CONFIG_JSON MACHINE_LEGACY_JSON
}

# ── Migration from the old profile-based machine.toml ──────────────────────

# If MACHINE_LEGACY_JSON has a profile= key and the named profile exists,
# pull its component_config + identity_overrides into the current state and
# add components from it as extra_components.
_machine_state_migrate_legacy() {
  local profile_name
  profile_name=$(printf '%s' "$MACHINE_LEGACY_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(d.get('profile','') or '')
")
  if [ -z "$profile_name" ]; then
    return 0
  fi

  log "Detected legacy machine.toml (profile=$profile_name) — migrating into new schema..."

  # Profiles can live in profiles/ (repo) or local/profiles/ (overlay)
  local profile_path=""
  for base in "$MACHINE_SETUP_DIR/local/profiles" "$MACHINE_SETUP_DIR/profiles"; do
    if [ -f "$base/${profile_name}.toml" ]; then
      profile_path="$base/${profile_name}.toml"
      break
    fi
  done
  if [ -z "$profile_path" ]; then
    warn "  Profile '$profile_name' not found on disk — nothing to migrate from."
    return 0
  fi

  # Read the profile + merge fields into current state
  local merged
  merged=$(python3 - "$profile_path" "$IDENTITY_OVERRIDES_JSON" "$COMPONENT_CONFIG_JSON" "$EXTRA_COMPONENTS" "$MACHINE_LEGACY_JSON" <<'PY'
import sys, json, tomllib
profile_path = sys.argv[1]
ident_over_existing = json.loads(sys.argv[2] or '{}')
comp_cfg_existing   = json.loads(sys.argv[3] or '{}')
extra_existing      = [c for c in (sys.argv[4] or '').split(',') if c]
legacy              = json.loads(sys.argv[5] or '{}')

with open(profile_path, 'rb') as f:
    profile = tomllib.load(f)

# component_config: profile -> machine.toml (existing wins, profile fills gaps)
for comp, cfg in (profile.get('component_config') or {}).items():
    if comp not in comp_cfg_existing:
        comp_cfg_existing[comp] = cfg
    else:
        for k, v in (cfg or {}).items():
            comp_cfg_existing[comp].setdefault(k, v)

# identity_overrides: convert from profile-shape (applies_to list, host inside)
# to machine.toml shape (host as nested key). Existing keys win.
for ident_name, ov in (profile.get('identity_overrides') or {}).items():
    target = ident_over_existing.setdefault(ident_name, {})
    for at in (ov.get('applies_to') or []):
        host = at.get('host')
        if not host:
            continue
        sub = target.setdefault(host, {})
        for k, v in at.items():
            if k == 'host':
                continue
            sub.setdefault(k, v)
    for k, v in ov.items():
        if k == 'applies_to':
            continue
        if not isinstance(v, dict):
            target.setdefault(k, v)

# extra_components: legacy components list - required (we don't know required
# here, so just use the full list; the bootstrap's plan() will dedupe required vs extra).
legacy_components = legacy.get('components') or profile.get('components') or []
for c in legacy_components:
    if c not in extra_existing:
        extra_existing.append(c)

print(json.dumps({
    'identity_overrides': ident_over_existing,
    'component_config':   comp_cfg_existing,
    'extra_components':   extra_existing,
}))
PY
)
  IDENTITY_OVERRIDES_JSON=$(printf '%s' "$merged" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['identity_overrides']))")
  COMPONENT_CONFIG_JSON=$(printf  '%s' "$merged" | python3 -c "import sys,json; print(json.dumps(json.load(sys.stdin)['component_config']))")
  EXTRA_COMPONENTS=$(printf       '%s' "$merged" | python3 -c "import sys,json; print(','.join(json.load(sys.stdin)['extra_components']))")
  MACHINE_LEGACY_JSON='{}'
  export IDENTITY_OVERRIDES_JSON COMPONENT_CONFIG_JSON EXTRA_COMPONENTS MACHINE_LEGACY_JSON
  log "  Migrated component_config + identity_overrides from profile."
}

# ── Identity picker ─────────────────────────────────────────────────────────

_NEW_IDENT_TAG="__create_new_identity__"

ui_pick_identities() {
  if [ -n "${MACHINE_SETUP_IDENTITIES:-}" ]; then
    IDENTITIES_OVERRIDE="$MACHINE_SETUP_IDENTITIES"
    log "Using identities from MACHINE_SETUP_IDENTITIES"
    export IDENTITIES_OVERRIDE
    return 0
  fi

  if [ -n "${IDENTITIES_OVERRIDE:-}" ] && [ "${RECONFIGURE:-0}" != "1" ]; then
    log "Using saved identities: $IDENTITIES_OVERRIDE"
    return 0
  fi

  if [ "${QUIET_MODE:-0}" = "1" ]; then
    log "Quiet mode: using saved identities (may be empty)."
    return 0
  fi

  _ui_prompt_identities || die "Identity selection cancelled."
  export IDENTITIES_OVERRIDE
}

_ui_prompt_identities() {
  while :; do
    local json names=() emails=() defaults=()
    json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" list-identities) \
      || die "Failed to list identities"

    names+=("$_NEW_IDENT_TAG")
    emails+=("[+] Create a new identity in Bitwarden...")
    defaults+=("0")

    # Pre-check identities that are in the saved list
    local saved_set=",${IDENTITIES_OVERRIDE:-},"

    while IFS= read -r line; do
      [ -z "$line" ] && continue
      local n d
      n=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['name'])")
      d=$(printf '%s' "$line" | python3 -c "
import sys,json; d=json.loads(sys.stdin.read())
src=d.get('source',''); g=d.get('git_name',''); e=d.get('git_email','')
print(f'{g} <{e}>  [{src}]' if e else f'(no email)  [{src}]')")
      names+=("$n")
      emails+=("$d")
      if [[ "$saved_set" == *",$n,"* ]]; then
        defaults+=("1")
      else
        defaults+=("0")
      fi
    done <<< "$json"

    if command -v whiptail >/dev/null 2>&1 && [ -r /dev/tty ]; then
      _ui_whiptail_identities names emails defaults
    else
      _ui_toggle_fallback_identities names emails defaults
    fi

    case ",$IDENTITIES_OVERRIDE," in
      *",$_NEW_IDENT_TAG,"*)
        IDENTITIES_OVERRIDE=$(printf '%s' "$IDENTITIES_OVERRIDE" \
          | tr ',' '\n' | grep -vxF "$_NEW_IDENT_TAG" | paste -sd ',' -)
        _ui_create_identity_wizard || die "Identity creation cancelled."
        continue
        ;;
    esac
    break
  done
}

_ui_whiptail_identities() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local args=()
  for i in "${!_names[@]}"; do
    local on="OFF"
    [ "${_defaults[$i]}" = "1" ] && on="ON"
    local d="${_descs[$i]}"
    [ "${#d}" -gt 50 ] && d="${d:0:47}..."
    args+=("${_names[$i]}" "$d" "$on")
  done
  local picked
  picked=$(whiptail \
    --title "machine-setup -- identities" \
    --checklist "Pick which identities to install on this machine." \
    20 80 12 \
    "${args[@]}" \
    3>&1 1>&2 2>&3 < /dev/tty) || return 1
  IDENTITIES_OVERRIDE=$(printf '%s' "$picked" | sed 's/"//g' | tr ' ' ',')
}

_ui_toggle_fallback_identities() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local -a sel=("${_defaults[@]}")
  [ -r /dev/tty ] || die "No /dev/tty -- set MACHINE_SETUP_IDENTITIES=<csv> or use --quiet"

  while :; do
    echo "" > /dev/tty
    echo "Identities -- toggle by number, ENTER to confirm:" > /dev/tty
    echo "" > /dev/tty
    local i
    for i in "${!_names[@]}"; do
      local mark="[ ]"
      [ "${sel[$i]}" = "1" ] && mark="[x]"
      if [ "${_names[$i]}" = "$_NEW_IDENT_TAG" ]; then
        printf "  %2d) %s %s\n" "$((i+1))" "$mark" "${_descs[$i]}" > /dev/tty
      else
        printf "  %2d) %s %-15s %s\n" "$((i+1))" "$mark" "${_names[$i]}" "${_descs[$i]}" > /dev/tty
      fi
    done
    echo "" > /dev/tty
    printf "> " > /dev/tty
    local input
    if ! read -r input < /dev/tty; then die "tty closed -- cannot read identity selection"; fi
    [ -z "$input" ] && break
    for tok in $input; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#_names[@]}" ]; then
        local idx=$((tok - 1))
        if [ "${sel[$idx]}" = "1" ]; then sel[$idx]=0; else sel[$idx]=1; fi
      else
        echo "  ignored: $tok" > /dev/tty
      fi
    done
  done

  local out=()
  for i in "${!_names[@]}"; do
    [ "${sel[$i]}" = "1" ] && out+=("${_names[$i]}")
  done
  IDENTITIES_OVERRIDE=$(IFS=,; printf '%s' "${out[*]}")
}

_ui_create_identity_wizard() {
  [ -r /dev/tty ] || { warn "no /dev/tty for wizard"; return 1; }
  local ident_name=""
  while :; do
    printf '\nNew identity name (alphanumeric/-/_): ' > /dev/tty
    if ! read -r ident_name < /dev/tty; then return 1; fi
    if [[ "$ident_name" =~ ^[A-Za-z0-9_-]+$ ]]; then break; fi
    echo "  invalid -- letters/digits/-/_ only" > /dev/tty
  done

  bash "$MACHINE_SETUP_DIR/tools/seed-bw-identity.sh" new "$ident_name" \
    || { warn "Identity creation failed"; return 1; }

  if [ -n "${MACHINE_SETUP_IDENTITY_REGISTRY:-}" ]; then
    bw_discover_identities "$MACHINE_SETUP_IDENTITY_REGISTRY" || true
  fi
}

# ── Per-identity auth picker ────────────────────────────────────────────────
#
# For each chosen identity, walk its applies_to entries and let the user
# confirm or override the credential_helper per host. Updates
# IDENTITY_OVERRIDES_JSON (machine.toml shape: {ident: {host: {field: val}}}).

ui_pick_auth() {
  if [ "${QUIET_MODE:-0}" = "1" ]; then
    log "Quiet mode: keeping existing auth settings."
    return 0
  fi
  if [ -z "${IDENTITIES_OVERRIDE:-}" ]; then
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    log "No /dev/tty -- skipping auth picker, keeping existing overrides."
    return 0
  fi

  echo "" > /dev/tty
  echo "--- Per-identity auth ---" > /dev/tty
  echo "(ENTER to keep current/default; or pick a number to override)" > /dev/tty

  local new_overrides_json
  new_overrides_json=$(python3 - "$IDENTITY_OVERRIDES_JSON" "$IDENTITIES_OVERRIDE" "${MACHINE_SETUP_IDENTITY_REGISTRY:-}" <<'PY'
import sys, json, os
existing  = json.loads(sys.argv[1] or '{}')
selected  = [n for n in (sys.argv[2] or '').split(',') if n]
registry_path = sys.argv[3]
registry = {}
if registry_path and os.path.exists(registry_path):
    with open(registry_path) as f:
        registry = json.load(f)
out = []
for name in selected:
    ident = registry.get(name, {})
    for at in (ident.get('applies_to') or []):
        host = at.get('host')
        if not host:
            continue
        current = existing.get(name, {}).get(host, {}).get('credential_helper') \
                  or at.get('credential_helper') or 'ssh'
        out.append({'identity': name, 'host': host, 'current': current})
print(json.dumps(out))
PY
)

  # Iterate each identity-host pair and prompt
  local current_json
  current_json=$(printf '%s' "$new_overrides_json")
  local result_json="$IDENTITY_OVERRIDES_JSON"

  while IFS=$'\t' read -r ident host current; do
    [ -z "$ident" ] && continue
    echo "" > /dev/tty
    echo "Identity '$ident' on $host -- credential helper [current: $current]" > /dev/tty
    echo "  1) ssh        — SSH-only auth (recommended for personal hosts)" > /dev/tty
    echo "  2) gcm        — Git Credential Manager (HTTPS via OAuth, needed for SSO)" > /dev/tty
    echo "  3) bitwarden  — username/api-token from a BW item" > /dev/tty
    echo "  4) none       — no helper (clears any existing one)" > /dev/tty
    printf "Pick [1-4] or ENTER to keep '%s': " "$current" > /dev/tty
    local choice
    if ! read -r choice < /dev/tty; then die "tty closed -- cannot read auth selection"; fi

    local new_helper="$current"
    case "$choice" in
      "")    new_helper="$current" ;;
      1) new_helper="ssh" ;;
      2) new_helper="gcm" ;;
      3) new_helper="bitwarden" ;;
      4) new_helper="none" ;;
      *) echo "  invalid; keeping $current" > /dev/tty ;;
    esac

    # Update result_json with this identity-host override
    result_json=$(python3 - "$result_json" "$ident" "$host" "$new_helper" <<'PY'
import sys, json
data = json.loads(sys.argv[1] or '{}')
ident, host, helper = sys.argv[2], sys.argv[3], sys.argv[4]
data.setdefault(ident, {}).setdefault(host, {})['credential_helper'] = helper
print(json.dumps(data))
PY
)
  done < <(printf '%s' "$current_json" | python3 -c "
import sys, json
for r in json.load(sys.stdin):
    print(f\"{r['identity']}\t{r['host']}\t{r['current']}\")
")

  IDENTITY_OVERRIDES_JSON="$result_json"
  export IDENTITY_OVERRIDES_JSON
}

# ── Component picker (required vs optional) ─────────────────────────────────

ui_pick_components() {
  if [ -n "${MACHINE_SETUP_COMPONENTS:-}" ]; then
    EXTRA_COMPONENTS="$MACHINE_SETUP_COMPONENTS"
    log "Using extra components from MACHINE_SETUP_COMPONENTS"
    export EXTRA_COMPONENTS
    return 0
  fi

  if [ -n "${EXTRA_COMPONENTS:-}" ] && [ "${RECONFIGURE:-0}" != "1" ]; then
    log "Using saved extra components: $EXTRA_COMPONENTS"
    return 0
  fi

  if [ "${QUIET_MODE:-0}" = "1" ]; then
    log "Quiet mode: using saved extra components (may be empty)."
    return 0
  fi

  _ui_prompt_components || die "Component selection cancelled."
  export EXTRA_COMPONENTS
}

_ui_prompt_components() {
  local os_tag="${MACHINE_SETUP_OS_TAG:-$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)}"

  # Required (derived from identities + OS)
  local required_json
  required_json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" derive-components \
    --identities "$IDENTITIES_OVERRIDE" --os-tag "$os_tag")

  # Show required as a header, not a checklist
  echo "" > /dev/tty
  echo "--- Required components ---" > /dev/tty
  printf '%s' "$required_json" | python3 -c "
import sys, json
for c in json.load(sys.stdin):
    print(f'  [R] {c}')" > /dev/tty

  # Optional = all components supported on this OS minus the required set
  local json all_names=() descs=() defaults=()
  json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" list-components --os-tag "$os_tag")
  local saved_set=",${EXTRA_COMPONENTS:-},"

  while IFS= read -r line; do
    [ -z "$line" ] && continue
    local n d
    n=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read())['name'])")
    # Skip components that are already in required
    if printf '%s' "$required_json" | python3 -c "
import sys, json
print('1' if '$n' in json.load(sys.stdin) else '0')
" | grep -q '^1$'; then
      continue
    fi
    d=$(printf '%s' "$line" | python3 -c "import sys,json; print(json.loads(sys.stdin.read()).get('description',''))")
    all_names+=("$n")
    descs+=("$d")
    if [[ "$saved_set" == *",$n,"* ]]; then
      defaults+=("1")
    else
      defaults+=("0")
    fi
  done <<< "$json"

  if [ "${#all_names[@]}" -eq 0 ]; then
    log "No optional components for $os_tag — proceeding with required only."
    EXTRA_COMPONENTS=""
    return 0
  fi

  echo "" > /dev/tty
  echo "--- Optional components ---" > /dev/tty
  if command -v whiptail >/dev/null 2>&1 && [ -r /dev/tty ]; then
    _ui_whiptail_optional all_names descs defaults
  else
    _ui_toggle_fallback_optional all_names descs defaults
  fi
}

_ui_whiptail_optional() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local args=()
  for i in "${!_names[@]}"; do
    local on="OFF"
    [ "${_defaults[$i]}" = "1" ] && on="ON"
    local d="${_descs[$i]}"
    [ "${#d}" -gt 50 ] && d="${d:0:47}..."
    args+=("${_names[$i]}" "$d" "$on")
  done
  local picked
  picked=$(whiptail \
    --title "machine-setup -- optional components" \
    --checklist "Toggle optional components. Required ones are auto-included." \
    22 80 14 \
    "${args[@]}" \
    3>&1 1>&2 2>&3 < /dev/tty) || return 1
  EXTRA_COMPONENTS=$(printf '%s' "$picked" | sed 's/"//g' | tr ' ' ',')
}

_ui_toggle_fallback_optional() {
  local -n _names=$1 _descs=$2 _defaults=$3
  local -a sel=("${_defaults[@]}")
  [ -r /dev/tty ] || die "No /dev/tty -- set MACHINE_SETUP_COMPONENTS=<csv> or use --quiet"

  while :; do
    echo "" > /dev/tty
    echo "Toggle by number, ENTER to confirm:" > /dev/tty
    echo "" > /dev/tty
    local i
    for i in "${!_names[@]}"; do
      local mark="[ ]"
      [ "${sel[$i]}" = "1" ] && mark="[x]"
      printf "  %2d) %s %-22s %s\n" "$((i+1))" "$mark" "${_names[$i]}" "${_descs[$i]}" > /dev/tty
    done
    echo "" > /dev/tty
    printf "> " > /dev/tty
    local input
    if ! read -r input < /dev/tty; then die "tty closed"; fi
    [ -z "$input" ] && break
    for tok in $input; do
      if [[ "$tok" =~ ^[0-9]+$ ]] && [ "$tok" -ge 1 ] && [ "$tok" -le "${#_names[@]}" ]; then
        local idx=$((tok - 1))
        if [ "${sel[$idx]}" = "1" ]; then sel[$idx]=0; else sel[$idx]=1; fi
      fi
    done
  done

  local out=()
  for i in "${!_names[@]}"; do
    [ "${sel[$i]}" = "1" ] && out+=("${_names[$i]}")
  done
  EXTRA_COMPONENTS=$(IFS=,; printf '%s' "${out[*]}")
}

# ── Component-config prompts ────────────────────────────────────────────────
#
# After components are picked, walk a handful of components that need config
# (chezmoi, dev-utilities, bitbucket-mcp, wsl-bootstrap) and prompt for any
# unset values. Existing component_config entries win — we only fill blanks.

ui_prompt_component_config() {
  if [ "${QUIET_MODE:-0}" = "1" ]; then
    return 0
  fi
  if [ ! -r /dev/tty ]; then
    return 0
  fi

  # All selected: required + extra. Easier to just prompt for any of the
  # known-needs-config components if they appear anywhere in the plan.
  local os_tag="${MACHINE_SETUP_OS_TAG:-$(python3 "$MACHINE_SETUP_DIR/lib/config.py" os-tag)}"
  local plan_components_json
  plan_components_json=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" plan \
    --identities "$IDENTITIES_OVERRIDE" \
    --extra-components "$EXTRA_COMPONENTS" \
    --identity-overrides "$IDENTITY_OVERRIDES_JSON" \
    --component-config "$COMPONENT_CONFIG_JSON" \
    --os-tag "$os_tag" 2>/dev/null \
    | python3 -c "
import sys, json
d = json.load(sys.stdin)
print(','.join(c['name'] for c in d['components']))
")

  _has() { case ",$plan_components_json," in *",$1,"*) return 0 ;; *) return 1 ;; esac; }

  # Helper: prompt if config field is missing/empty
  _prompt_component_field() {
    local comp="$1" field="$2" question="$3"
    local current
    current=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
print((d.get('$comp') or {}).get('$field') or '')
")
    if [ -n "$current" ]; then
      return 0  # already set
    fi
    printf '%s\n' "$question" > /dev/tty
    printf '> ' > /dev/tty
    local val
    if ! read -r val < /dev/tty; then return 0; fi
    if [ -z "$val" ]; then return 0; fi
    COMPONENT_CONFIG_JSON=$(printf '%s' "$COMPONENT_CONFIG_JSON" | python3 -c "
import sys, json
d = json.load(sys.stdin)
d.setdefault('$comp', {})['$field'] = '''$val'''
print(json.dumps(d))
")
  }

  echo "" > /dev/tty
  echo "--- Component configuration ---" > /dev/tty
  echo "(ENTER to skip / leave unset)" > /dev/tty

  if _has chezmoi; then
    echo "" > /dev/tty
    echo "[chezmoi] dotfiles repo URL (e.g. https://github.com/<you>/dotfiles.git):" > /dev/tty
    _prompt_component_field chezmoi repo "(repo URL)"
  fi

  if _has dev-utilities; then
    echo "" > /dev/tty
    echo "[dev-utilities] git URL of repo to clone:" > /dev/tty
    _prompt_component_field dev-utilities repo "(git URL)"
  fi

  if _has bitbucket-mcp; then
    echo "" > /dev/tty
    echo "[bitbucket-mcp] path to MCP source dir (default: ~/.local/share/dev-utilities/bitbucket-mcp):" > /dev/tty
    _prompt_component_field bitbucket-mcp path "(path)"
  fi

  if _has wsl-bootstrap; then
    echo "" > /dev/tty
    echo "[wsl-bootstrap] WSL distro name (default: Ubuntu):" > /dev/tty
    _prompt_component_field wsl-bootstrap distro "(distro)"
  fi

  export COMPONENT_CONFIG_JSON
}
