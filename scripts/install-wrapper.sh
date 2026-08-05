#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/madebycli/nix-backup.git"
readonly TARGET_USER="xxxxx"
readonly DEFAULT_CHECKOUT="/etc/nixos/nix-backup"
readonly AUTHORIZED_KEYS_SOURCE="/home/${TARGET_USER}/.ssh/authorized_keys"
readonly EXPECTED_WIFI_USB_ID="13d3:3306"

CHECKOUT="$DEFAULT_CHECKOUT"
args=("$@")

fail() {
  printf '\nError: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

has_expected_wifi_adapter() {
  local device vendor product

  for device in /sys/bus/usb/devices/*; do
    [[ -r "$device/idVendor" && -r "$device/idProduct" ]] || continue
    vendor="$(tr '[:upper:]' '[:lower:]' < "$device/idVendor")"
    product="$(tr '[:upper:]' '[:lower:]' < "$device/idProduct")"
    [[ "${vendor}:${product}" == "$EXPECTED_WIFI_USB_ID" ]] && return 0
  done

  return 1
}

clone_checkout() {
  log "Cloning configuration into $CHECKOUT before preserving SSH access"
  "${SUDO[@]}" install -d -m 0755 "$(dirname "$CHECKOUT")"
  "${SUDO[@]}" git clone "$REPO_URL" "$CHECKOUT"
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
has_expected_wifi_adapter \
  || fail "expected backup-server Wi-Fi adapter $EXPECTED_WIFI_USB_ID is not connected; refusing to install on the wrong machine"

if [[ $EUID -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || fail "sudo is required"
  SUDO=(sudo)
fi

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
fi

readonly AUTHORIZED_KEYS_TARGET="$CHECKOUT/hosts/github-vault/authorized_keys"
readonly AUTHORIZED_KEYS_REPO_PATH="hosts/github-vault/authorized_keys"

# A previously interrupted or stale checkout can be missing the working-tree
# copy even though the placeholder is tracked in HEAD. Restore it before the
# real key is copied. This does not touch any machine-specific key content.
if [[ ! -f "$AUTHORIZED_KEYS_TARGET" ]] \
  && "${SUDO[@]}" git -C "$CHECKOUT" cat-file -e "HEAD:${AUTHORIZED_KEYS_REPO_PATH}" 2>/dev/null; then
  log "Restoring missing authorized_keys placeholder from the repository"
  "${SUDO[@]}" git -C "$CHECKOUT" restore --source=HEAD -- "$AUTHORIZED_KEYS_REPO_PATH"
fi

[[ -f "$AUTHORIZED_KEYS_TARGET" ]] \
  || fail "authorized_keys placeholder is missing after refresh: $AUTHORIZED_KEYS_TARGET"

log "Preserving SSH access for $TARGET_USER"
"${SUDO[@]}" install -m 0644 "$AUTHORIZED_KEYS_SOURCE" "$AUTHORIZED_KEYS_TARGET"
"${SUDO[@]}" git -C "$CHECKOUT" update-index --skip-worktree \
  "$AUTHORIZED_KEYS_REPO_PATH"

exec bash "$CHECKOUT/scripts/install.sh" "${args[@]}"
