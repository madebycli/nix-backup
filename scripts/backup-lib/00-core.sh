#!/usr/bin/env bash
set -Eeuo pipefail

umask 077

: "${BACKUP_OWNER:=madebycli}"
: "${BACKUP_SCOPE:=owner}"
: "${BACKUP_ROOT:=/var/lib/nix-backup/data}"
: "${GH_TOKEN_FILE:=/var/lib/nix-backup/secrets/github-token}"
: "${STATUS_REPOSITORY:=madebycli/nix-backup}"
: "${STATUS_BRANCH:=main}"
: "${INCLUDE_ACTION_LOGS:=true}"
: "${INCLUDE_ARTIFACTS:=true}"
: "${INCLUDE_RELEASE_ASSETS:=true}"
: "${MIN_FREE_GIB:=10}"
: "${NETWORK_WAIT_SECONDS:=600}"

readonly TIMESTAMP="$(date -u '+%Y-%m-%dT%H-%M-%SZ')"
readonly HOST_ID="$(hostname -s 2>/dev/null || hostname)"
readonly RUN_ROOT="${BACKUP_ROOT}/runs/${TIMESTAMP}"
readonly RUN_TMP="${BACKUP_ROOT}/tmp/${TIMESTAMP}"
readonly LOG_FILE="${RUN_ROOT}/backup.log"
readonly STATUS_LOCAL="${RUN_ROOT}/status.json"
readonly REPOSITORIES_JSON="${RUN_ROOT}/repositories.json"
readonly FAILURES_JSONL="${RUN_ROOT}/failures.jsonl"

SUCCESS_COUNT=0
FAILURE_COUNT=0
TOTAL_COUNT=0
STATUS_UPLOAD_OK=false

mkdir -p "$RUN_ROOT" "$RUN_TMP" "${BACKUP_ROOT}/repos" "${BACKUP_ROOT}/mirrors"
touch "$FAILURES_JSONL"
exec > >(tee -a "$LOG_FILE") 2>&1

cleanup() {
  rm -rf "$RUN_TMP"
}
trap cleanup EXIT

log() {
  printf '%s %s\n' "$(date -u '+%Y-%m-%dT%H:%M:%SZ')" "$*"
}

warn() {
  log "WARN: $*"
}

record_failure() {
  local repo="$1"
  local stage="$2"
  local message="$3"
  FAILURE_COUNT=$((FAILURE_COUNT + 1))
  jq -nc \
    --arg repository "$repo" \
    --arg stage "$stage" \
    --arg message "$message" \
    '{repository:$repository,stage:$stage,message:$message}' >> "$FAILURES_JSONL"
  warn "$repo [$stage]: $message"
}

bool_is_true() {
  case "${1,,}" in
    1|true|yes|on) return 0 ;;
    *) return 1 ;;
  esac
}

require_command() {
  command -v "$1" >/dev/null 2>&1 || {
    log "FATAL: required command missing: $1"
    exit 90
  }
}

for command in base64 curl date df find git gh hostname jq mkdir mktemp sha256sum sort tar tee zstd; do
  require_command "$command"
done

if [[ ! -s "$GH_TOKEN_FILE" ]]; then
  log "FATAL: token file missing or empty: $GH_TOKEN_FILE"
  exit 91
fi

export GH_TOKEN="$(tr -d '\r\n' < "$GH_TOKEN_FILE")"
export GITHUB_TOKEN="$GH_TOKEN"
export GIT_TERMINAL_PROMPT=0
export GH_PAGER=cat

# Git invokes this helper only for credential lookup. The token stays in the
# service environment and is never written into repository remotes.
readonly GIT_CREDENTIAL_HELPER='!f() { if [ "$1" = get ]; then echo username=x-access-token; echo "password=$GH_TOKEN"; fi; }; f'

git_auth() {
  git -c credential.helper= -c "credential.helper=${GIT_CREDENTIAL_HELPER}" "$@"
}

api_object() {
  local endpoint="$1"
  local destination="$2"
  local temporary="${destination}.tmp"
  if gh api -H 'Accept: application/vnd.github+json' "$endpoint" > "$temporary" 2>/dev/null; then
    jq . "$temporary" > "$destination"
    rm -f "$temporary"
    return 0
  fi
  rm -f "$temporary"
  return 1
}

api_array() {
  local endpoint="$1"
  local destination="$2"
  local temporary="${destination}.tmp"
  if gh api --paginate -H 'Accept: application/vnd.github+json' "$endpoint" 2>/dev/null \
      | jq -s 'if length == 0 then [] elif (.[0] | type) == "array" then add else . end' \
      > "$temporary"; then
    mv "$temporary" "$destination"
    return 0
  fi
  rm -f "$temporary"
  return 1
}

api_optional_object() {
  local endpoint="$1"
  local destination="$2"
  local label="$3"
  api_object "$endpoint" "$destination" || {
    warn "$label could not be exported"
    printf '{"unavailable":true,"endpoint":%s}\n' "$(jq -Rn --arg x "$endpoint" '$x')" > "$destination"
  }
}

api_optional_array() {
  local endpoint="$1"
  local destination="$2"
  local label="$3"
  api_array "$endpoint" "$destination" || {
    warn "$label could not be exported"
    printf '[]\n' > "$destination"
  }
}

api_field_array() {
  local endpoint="$1"
  local field="$2"
  local destination="$3"
  local temporary="${destination}.tmp"
  if gh api --paginate -H 'Accept: application/vnd.github+json' "$endpoint" 2>/dev/null \
      | jq -s --arg field "$field" '[.[][$field][]?]' > "$temporary"; then
    mv "$temporary" "$destination"
    return 0
  fi
  rm -f "$temporary"
  return 1
}

api_optional_field_array() {
  local endpoint="$1"
  local field="$2"
  local destination="$3"
  local label="$4"
  api_field_array "$endpoint" "$field" "$destination" || {
    warn "$label could not be exported"
    printf '[]\n' > "$destination"
  }
}

wait_for_github() {
  local elapsed=0
  local delay=5
  while (( elapsed < NETWORK_WAIT_SECONDS )); do
    if gh api user --jq .login >/dev/null 2>&1; then
      return 0
    fi
    log "GitHub not reachable/authenticated yet; retrying in ${delay}s"
    sleep "$delay"
    elapsed=$((elapsed + delay))
    if (( delay < 30 )); then
      delay=$((delay + 5))
    fi
  done
  return 1
}

check_free_space() {
  local available_kib required_kib
  available_kib="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {print $4}')"
  required_kib=$((MIN_FREE_GIB * 1024 * 1024))
  if (( available_kib < required_kib )); then
    log "FATAL: only $((available_kib / 1024 / 1024)) GiB free; ${MIN_FREE_GIB} GiB required"
    return 1
  fi
}

list_repositories() {
  local authenticated_login owner_type endpoint
  authenticated_login="$(gh api user --jq .login)"
  owner_type="$(gh api "/users/${BACKUP_OWNER}" --jq .type)"

  case "$BACKUP_SCOPE" in
    owner)
      if [[ "$owner_type" == "User" && "${authenticated_login,,}" == "${BACKUP_OWNER,,}" ]]; then
        endpoint='/user/repos?affiliation=owner&sort=full_name&direction=asc&per_page=100'
      elif [[ "$owner_type" == "Organization" ]]; then
        endpoint="/orgs/${BACKUP_OWNER}/repos?type=all&sort=full_name&direction=asc&per_page=100"
      else
        endpoint="/users/${BACKUP_OWNER}/repos?type=owner&sort=full_name&direction=asc&per_page=100"
        warn "authenticated user is ${authenticated_login}; private repositories of ${BACKUP_OWNER} may be unavailable"
      fi
      ;;
    accessible)
      endpoint='/user/repos?affiliation=owner,collaborator,organization_member&sort=full_name&direction=asc&per_page=100'
      ;;
    *)
      log "FATAL: BACKUP_SCOPE must be owner or accessible"
      return 1
      ;;
  esac

  gh api --paginate -H 'Accept: application/vnd.github+json' "$endpoint" \
    | jq -s 'add | unique_by(.full_name) | sort_by(.full_name)' > "$REPOSITORIES_JSON"
}

safe_asset_name() {
  local name="$1"
  name="${name//\//_}"
  name="${name//$'\n'/_}"
  printf '%s' "$name"
}
