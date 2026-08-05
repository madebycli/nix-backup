#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/madebycli/nix-backup.git"
readonly TARGET_USER="xxxxx"
readonly DEFAULT_CHECKOUT="/etc/nixos/nix-backup"
readonly AUTHORIZED_KEYS_SOURCE="/home/${TARGET_USER}/.ssh/authorized_keys"

CHECKOUT="$DEFAULT_CHECKOUT"
args=("$@")

fail() {
  printf '\nError: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

# Read --checkout without consuming the arguments forwarded to install.sh.
for ((index = 0; index < ${#args[@]}; index++)); do
  if [[ "${args[$index]}" == "--checkout" ]]; then
    (( index + 1 < ${#args[@]} )) || fail "--checkout requires a path"
    CHECKOUT="${args[$((index + 1))]}"
  fi
done

[[ -e /etc/NIXOS ]] || fail "this does not appear to be NixOS"
id "$TARGET_USER" >/dev/null 2>&1 || fail "required user does not exist: $TARGET_USER"
[[ -s "$AUTHORIZED_KEYS_SOURCE" ]] \
  || fail "$AUTHORIZED_KEYS_SOURCE is missing or empty; install your PC SSH public key first"
grep -Eq '^(ssh-(ed25519|rsa)|ecdsa-|sk-(ssh-|ecdsa-))' "$AUTHORIZED_KEYS_SOURCE" \
  || fail "$AUTHORIZED_KEYS_SOURCE contains no recognizable SSH public key"

if [[ $EUID -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || fail "sudo is required"
  SUDO=(sudo)
fi

if [[ ! -e "$CHECKOUT" ]]; then
  log "Cloning configuration into $CHECKOUT before preserving SSH access"
  "${SUDO[@]}" install -d -m 0755 "$(dirname "$CHECKOUT")"
  "${SUDO[@]}" git clone "$REPO_URL" "$CHECKOUT"
elif [[ ! -d "$CHECKOUT/.git" ]]; then
  fail "$CHECKOUT exists but is not a Git repository"
fi

readonly AUTHORIZED_KEYS_TARGET="$CHECKOUT/hosts/github-vault/authorized_keys"
[[ -f "$AUTHORIZED_KEYS_TARGET" ]] \
  || fail "authorized_keys placeholder is missing: $AUTHORIZED_KEYS_TARGET"

log "Preserving SSH access for $TARGET_USER"
"${SUDO[@]}" install -m 0644 "$AUTHORIZED_KEYS_SOURCE" "$AUTHORIZED_KEYS_TARGET"
"${SUDO[@]}" git -C "$CHECKOUT" update-index --skip-worktree \
  hosts/github-vault/authorized_keys

exec bash "$CHECKOUT/scripts/install.sh" "${args[@]}"
