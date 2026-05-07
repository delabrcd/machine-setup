#!/usr/bin/env bash
# Profile-driven component dispatcher for Linux/WSL.
# Bash-side glue around lib/config.py: parses the JSON plan and runs each
# component's linux.sh in dependency order, once per identity if requested.
#
# Caller (bootstrap.sh) is expected to have sourced lib/common.sh and set
# MACHINE_SETUP_DIR (the repo root).
#
# Failure model: a component error doesn't abort the run. The driver collects
# names into FAILED_STEPS and prints them at the end so the user knows what
# to re-run.

# shellcheck disable=SC2034  # FAILED_STEPS is consumed by the driver caller
FAILED_STEPS=()

_record_failure() {
  warn "Component '$1' had errors — continuing. Re-run bootstrap.sh after fixing."
  FAILED_STEPS+=("$1")
}

# Cached JSON plan + helpers --------------------------------------------------

driver_load_plan() {
  local profile="$1"
  local components="${2:-}"   # optional: comma-separated override
  local args=(resolve "$profile")
  [ -n "${MACHINE_SETUP_OS_TAG:-}" ] && args+=(--os-tag "$MACHINE_SETUP_OS_TAG")
  [ -n "$components" ] && args+=(--components "$components")
  PLAN_JSON=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" "${args[@]}") \
    || die "Failed to resolve profile '$profile'"
  export PLAN_JSON
}

_jq_python() {
  # Tiny `python -c` fallback that reads JSON from stdin and runs an expression.
  # We avoid a hard `jq` dep — Python is already required.
  python3 -c "import sys, json; data=json.load(sys.stdin); $1"
}

driver_components() {
  printf '%s\n' "$PLAN_JSON" | _jq_python \
    'print("\n".join(c["name"] for c in data["components"]))'
}

driver_identities() {
  printf '%s\n' "$PLAN_JSON" | _jq_python \
    'print("\n".join(i["name"] for i in data["identities"]))'
}

driver_default_identity() {
  printf '%s\n' "$PLAN_JSON" | _jq_python \
    'd=[i for i in data["identities"] if i.get("default")]; print(d[0]["name"] if d else "")'
}

_component_field() {
  # Read a field off the component dict for a given component name.
  local name="$1" field="$2"
  printf '%s\n' "$PLAN_JSON" | _jq_python "
c = next((c for c in data['components'] if c['name'] == '$name'), None)
print('' if not c else c.get('$field', '') or '')
"
}

# Identity-env exporter -------------------------------------------------------

# Usage: driver_export_identity_env <identity-name>
# After this, the current shell has IDENT_NAME, IDENT_GIT_NAME, etc. set so
# the next sourced component script sees the active identity.
driver_export_identity_env() {
  local name="$1"
  local env_lines
  env_lines=$(python3 "$MACHINE_SETUP_DIR/lib/config.py" identity-env "$name") \
    || { warn "Failed to load identity '$name'"; return 1; }
  # Prefix each line with `export ` and eval.
  while IFS= read -r line; do
    [ -n "$line" ] && eval "export $line"
  done <<< "$env_lines"
}

driver_clear_identity_env() {
  unset IDENT_NAME IDENT_GIT_NAME IDENT_GIT_EMAIL IDENT_BW_SSH_ITEM \
        IDENT_SSH_KEY_BASENAME IDENT_DEFAULT IDENT_APPLIES_TO_JSON
}

# Component runner ------------------------------------------------------------

# Usage: driver_run_component <name>
# Sources the component's linux.sh once (or once per identity if per_identity=true).
# Components see common.sh helpers (already sourced by bootstrap.sh) and any
# IDENT_* vars set via driver_export_identity_env.
driver_run_component() {
  local name="$1"
  local script per_identity config_json
  script=$(_component_field "$name" "script")
  per_identity=$(printf '%s\n' "$PLAN_JSON" | _jq_python "
c = next((c for c in data['components'] if c['name'] == '$name'), None)
print('1' if c and c.get('per_identity') else '0')
")
  config_json=$(printf '%s\n' "$PLAN_JSON" | _jq_python "
import json
c = next((c for c in data['components'] if c['name'] == '$name'), None)
print(json.dumps(c.get('config', {}) if c else {}))
")
  export COMPONENT_CONFIG_JSON="$config_json"

  step "Component: $name"
  if [ -z "$script" ] || [ ! -f "$script" ]; then
    warn "No linux.sh for '$name' — skipping"
    unset COMPONENT_CONFIG_JSON
    return 0
  fi

  if [ "$per_identity" = "1" ]; then
    local count=0
    while IFS= read -r ident; do
      [ -z "$ident" ] && continue
      count=$((count + 1))
      log "↳ identity: $ident"
      driver_export_identity_env "$ident" || { _record_failure "$name [$ident]"; continue; }
      ( . "$script" ) || _record_failure "$name [$ident]"
      driver_clear_identity_env
    done < <(driver_identities)
    if [ "$count" = "0" ]; then
      warn "Component '$name' is per-identity but profile has no identities — skipping"
    fi
  else
    ( . "$script" ) || _record_failure "$name"
  fi
  unset COMPONENT_CONFIG_JSON
}

driver_run_all() {
  while IFS= read -r comp; do
    [ -z "$comp" ] && continue
    driver_run_component "$comp"
  done < <(driver_components)
}

driver_summary() {
  echo ""
  echo -e "${BOLD}==============================${NC}"
  if [ "${#FAILED_STEPS[@]}" -eq 0 ]; then
    echo -e "${GREEN}Bootstrap complete!${NC}"
  else
    echo -e "${YELLOW}Bootstrap finished with errors.${NC}"
    echo -e "${BOLD}Re-run after fixing:${NC}"
    for s in "${FAILED_STEPS[@]}"; do echo "  - $s"; done
  fi
  echo -e "${BOLD}==============================${NC}"
}
