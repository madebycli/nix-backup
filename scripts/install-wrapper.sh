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

make_checkout_readable() {
  [[ -e "$CHECKOUT" ]] || return 0
  "${SUDO[@]}" chmod -R u=rwX,go=rX "$CHECKOUT"
}

clone_checkout() {
  log "Cloning configuration into $CHECKOUT before preserving SSH access"
  "${SUDO[@]}" install -d -m 0755 "$(dirname "$CHECKOUT")"
  "${SUDO[@]}" git clone "$REPO_URL" "$CHECKOUT"
  make_checkout_readable
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

# Earlier interrupted runs may have created a root-owned checkout under umask
# 077. Make it traversable before testing whether it is a Git repository.
make_checkout_readable

if [[ ! -e "$CHECKOUT" ]]; then
  clone_checkout
elif [[ ! -d "$CHECKOUT/.git" ]]; then
  stale_checkout="${CHECKOUT}.incomplete-$(date +%Y%m%d-%H%M%S)"
  log "Preserving incomplete checkout as $stale_checkout"
  "${SUDO[@]}" mv "$CHECKOUT" "$stale_checkout"
  clone_checkout
else
  remote="$("${SUDO[@]}" git -C "$CHECKOUT" remote get-url origin 2>/dev/null || true)"
  [[ "$remote" == "$REPO_URL" || "$remote" == "git@github.com:madebycli/nix-backup.git" ]] \
    || fail "unexpected origin remote: $remote"

  log "Refreshing existing installer checkout"
  "${SUDO[@]}" git -C "$CHECKOUT" pull --ff-only
  make_checkout_readable
fi

readonly AUTHORIZED_KEYS_TARGET="$CHECKOUT/hosts/github-vault/authorized_keys"
readonly AUTHORIZED_KEYS_REPO_PATH="hosts/github-vault/authorized_keys"

# Nix flakes include only paths tracked by Git. Verify that the placeholder is
# present in HEAD, but do not depend on its working-tree copy: some Git setups
# can suppress that copy through index flags. Install the real key directly.
"${SUDO[@]}" git -C "$CHECKOUT" cat-file -e \
  "HEAD:${AUTHORIZED_KEYS_REPO_PATH}" 2>/dev/null \
  || fail "authorized_keys path is not tracked in the repository: $AUTHORIZED_KEYS_REPO_PATH"

log "Preserving SSH access for $TARGET_USER"
"${SUDO[@]}" install -d -m 0755 "$(dirname "$AUTHORIZED_KEYS_TARGET")"
"${SUDO[@]}" git -C "$CHECKOUT" update-index --no-skip-worktree \
  "$AUTHORIZED_KEYS_REPO_PATH" 2>/dev/null || true
"${SUDO[@]}" install -m 0644 "$AUTHORIZED_KEYS_SOURCE" "$AUTHORIZED_KEYS_TARGET"
"${SUDO[@]}" git -C "$CHECKOUT" update-index --skip-worktree \
  "$AUTHORIZED_KEYS_REPO_PATH"
make_checkout_readable

exec bash "$CHECKOUT/scripts/install.sh" "${args[@]}"
