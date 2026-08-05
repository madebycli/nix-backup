#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/madebycli/nix-backup.git"
readonly PROFILE="github-vault"
readonly HARDWARE_SOURCE="/etc/nixos/hardware-configuration.nix"
readonly TOKEN_TARGET="/var/lib/nix-backup/secrets/github-token"
readonly ARM_FILE="/var/lib/nix-backup/armed"
readonly WIFI_CONNECTION_NAME="nix-backup-wifi"

CHECKOUT="/etc/nixos/nix-backup"
TOKEN_SOURCE=""
BIOS_DISK=""
WIFI_SSID=""
WIFI_PASSWORD_FILE=""
WIFI_INTERFACE=""
AUTO_YES=false
ARM_AFTER_INSTALL=true

usage() {
  cat <<'USAGE'
Install nix-backup on an already bootable minimal NixOS installation.

Recommended command:
  nix run github:madebycli/nix-backup#install

Options:
  --checkout PATH       Configuration checkout. Default: /etc/nixos/nix-backup
  --token-file PATH     Read the GitHub token from this file instead of prompting.
  --bios-disk PATH      GRUB installation disk for legacy BIOS, for example /dev/sda.
  --wifi-ssid SSID      Create/refresh a persistent NetworkManager Wi-Fi profile.
  --wifi-password-file PATH
                        File containing the Wi-Fi password (used with --wifi-ssid).
  --wifi-interface IF   Optionally bind the Wi-Fi profile to an interface.
  --no-arm              Do not run backup/shutdown automatically on the next boot.
                        Use this for the first Wi-Fi-only reboot test.
  --yes, -y             Build and switch without a confirmation prompt.
  -h, --help            Show this help.

On UEFI systems the installer configures systemd-boot automatically. On legacy
BIOS systems --bios-disk is required. The currently generated NixOS hardware
configuration and the existing SSH authorized_keys are preserved locally.

Ethernet is configured as the preferred route (metric 100). Wi-Fi is configured
as an automatic fallback (metric 600), so unplugging Ethernet makes Wi-Fi take
over without changing the backup service.
USAGE
}

die() {
  printf '\nError: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '\n==> %s\n' "$*"
}

while (($#)); do
  case "$1" in
    --checkout)
      [[ $# -ge 2 ]] || die "--checkout requires a path"
      CHECKOUT="$2"
      shift 2
      ;;
    --token-file)
      [[ $# -ge 2 ]] || die "--token-file requires a path"
      TOKEN_SOURCE="$2"
      shift 2
      ;;
    --bios-disk)
      [[ $# -ge 2 ]] || die "--bios-disk requires a disk path"
      BIOS_DISK="$2"
      shift 2
      ;;
    --wifi-ssid)
      [[ $# -ge 2 ]] || die "--wifi-ssid requires a value"
      WIFI_SSID="$2"
      shift 2
      ;;
    --wifi-password-file)
      [[ $# -ge 2 ]] || die "--wifi-password-file requires a path"
      WIFI_PASSWORD_FILE="$2"
      shift 2
      ;;
    --wifi-interface)
      [[ $# -ge 2 ]] || die "--wifi-interface requires a name"
      WIFI_INTERFACE="$2"
      shift 2
      ;;
    --no-arm)
      ARM_AFTER_INSTALL=false
      shift
      ;;
    --yes|-y)
      AUTO_YES=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      die "unknown option: $1"
      ;;
  esac
done

[[ -e /etc/NIXOS ]] || die "this does not appear to be NixOS"
if [[ -n "$WIFI_SSID" ]]; then
  [[ -n "$WIFI_PASSWORD_FILE" ]] || die "--wifi-ssid requires --wifi-password-file"
  [[ -s "$WIFI_PASSWORD_FILE" ]] || die "Wi-Fi password file missing or empty: $WIFI_PASSWORD_FILE"
  [[ "$WIFI_SSID" != *$'\n'* && "$WIFI_SSID" != *$'\r'* ]] || die "Wi-Fi SSID contains a newline"
elif [[ -n "$WIFI_PASSWORD_FILE" || -n "$WIFI_INTERFACE" ]]; then
  die "Wi-Fi password/interface options require --wifi-ssid"
fi

for command in git gh nix nixos-rebuild; do
  command -v "$command" >/dev/null 2>&1 || die "required command missing: $command"
done

if [[ $EUID -eq 0 ]]; then
  SUDO=()
else
  command -v sudo >/dev/null 2>&1 || die "sudo is required when not running as root"
  SUDO=(sudo)
fi

work_dir="$(mktemp -d)"
cleanup() {
  rm -rf "$work_dir"
}
trap cleanup EXIT

if [[ -f "$HARDWARE_SOURCE" ]]; then
  cp "$HARDWARE_SOURCE" "$work_dir/hardware-configuration.nix"
else
  command -v nixos-generate-config >/dev/null 2>&1 \
    || die "$HARDWARE_SOURCE is missing and nixos-generate-config is unavailable"
  log "Generating hardware configuration"
  "${SUDO[@]}" nixos-generate-config --show-hardware-config > "$work_dir/hardware-configuration.nix"
fi

if [[ -d /sys/firmware/efi ]]; then
  cat > "$work_dir/boot-loader.nix" <<'NIX'
{ ... }:
{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
NIX
  log "Detected UEFI; systemd-boot will be used"
else
  [[ -n "$BIOS_DISK" ]] || die "legacy BIOS detected; rerun with --bios-disk /dev/sdX"
  [[ -b "$BIOS_DISK" ]] || die "BIOS disk is not a block device: $BIOS_DISK"
  cat > "$work_dir/boot-loader.nix" <<NIX
{ ... }:
{
  boot.loader.grub.enable = true;
  boot.loader.grub.device = "${BIOS_DISK}";
}
NIX
  log "Detected legacy BIOS; GRUB will be installed to $BIOS_DISK"
fi

if [[ ! -e "$CHECKOUT" ]]; then
  log "Cloning configuration into $CHECKOUT"
  "${SUDO[@]}" install -d -m 0755 "$(dirname "$CHECKOUT")"
  "${SUDO[@]}" git clone "$REPO_URL" "$CHECKOUT"
elif [[ ! -d "$CHECKOUT/.git" ]]; then
  die "$CHECKOUT exists but is not a Git repository"
else
  remote="$("${SUDO[@]}" git -C "$CHECKOUT" remote get-url origin 2>/dev/null || true)"
  [[ "$remote" == "$REPO_URL" || "$remote" == "git@github.com:madebycli/nix-backup.git" ]] \
    || die "unexpected origin remote: $remote"
  [[ -z "$("${SUDO[@]}" git -C "$CHECKOUT" status --porcelain --untracked-files=no)" ]] \
    || die "tracked local changes exist in $CHECKOUT"
  log "Updating existing checkout"
  "${SUDO[@]}" git -C "$CHECKOUT" pull --ff-only
fi

hardware_target="$CHECKOUT/hosts/github-vault/hardware-configuration.nix"
boot_target="$CHECKOUT/hosts/github-vault/boot-loader.nix"
[[ -f "$hardware_target" ]] || die "hardware placeholder missing in repository"
[[ -f "$boot_target" ]] || die "boot-loader placeholder missing in repository"

log "Installing machine-specific hardware and boot configuration"
"${SUDO[@]}" install -m 0644 "$work_dir/hardware-configuration.nix" "$hardware_target"
"${SUDO[@]}" install -m 0644 "$work_dir/boot-loader.nix" "$boot_target"
"${SUDO[@]}" git -C "$CHECKOUT" update-index --skip-worktree \
  hosts/github-vault/hardware-configuration.nix \
  hosts/github-vault/boot-loader.nix

if [[ -n "$TOKEN_SOURCE" ]]; then
  [[ -s "$TOKEN_SOURCE" ]] || die "token file missing or empty: $TOKEN_SOURCE"
  token="$(tr -d '\r\n' < "$TOKEN_SOURCE")"
elif [[ -n "${GH_TOKEN:-}" ]]; then
  token="$GH_TOKEN"
else
  [[ -t 0 ]] || die "no token supplied; use --token-file or GH_TOKEN"
  printf '\nGitHub token: '
  read -r -s token
  printf '\n'
fi
[[ -n "$token" ]] || die "GitHub token is empty"

log "Validating GitHub token"
authenticated_login="$(GH_TOKEN="$token" gh api user --jq .login)" \
  || die "GitHub token authentication failed"
printf 'Authenticated as: %s\n' "$authenticated_login"
[[ "${authenticated_login,,}" == "madebycli" ]] \
  || printf 'WARNING: configuration owner is madebycli, but token belongs to %s.\n' "$authenticated_login"
GH_TOKEN="$token" gh api /repos/madebycli/nix-backup --jq .full_name >/dev/null \
  || die "token cannot read madebycli/nix-backup"

printf '%s' "$token" > "$work_dir/github-token"
"${SUDO[@]}" install -d -m 0700 /var/lib/nix-backup/secrets
"${SUDO[@]}" install -m 0600 "$work_dir/github-token" "$TOKEN_TARGET"
rm -f "$work_dir/github-token"
unset token

# Prevent a newly enabled unit from starting during nixos-rebuild switch. It is
# armed only after the switch, unless --no-arm was selected for a network test.
"${SUDO[@]}" rm -f "$ARM_FILE"

cd "$CHECKOUT"
log "Checking the flake"
"${SUDO[@]}" nix flake check --no-build
log "Building NixOS profile $PROFILE"
"${SUDO[@]}" nixos-rebuild build --flake ".#${PROFILE}"

if ! $AUTO_YES; then
  printf '\nBuild successful. Activate the backup appliance configuration? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES|j|J|ja|JA) ;;
    *)
      printf 'No switch performed. Build result: %s/result\n' "$CHECKOUT"
      exit 0
      ;;
  esac
fi

log "Activating NixOS configuration"
"${SUDO[@]}" nixos-rebuild switch --flake ".#${PROFILE}"

if [[ -n "$WIFI_SSID" ]]; then
  command -v nmcli >/dev/null 2>&1 || die "nmcli is unavailable after the switch"
  wifi_password="$(tr -d '\r\n' < "$WIFI_PASSWORD_FILE")"
  [[ -n "$wifi_password" ]] || die "Wi-Fi password is empty"

  log "Creating persistent Wi-Fi fallback profile for $WIFI_SSID"
  "${SUDO[@]}" nmcli connection delete id "$WIFI_CONNECTION_NAME" >/dev/null 2>&1 || true

  wifi_add=(
    connection add
    type wifi
    con-name "$WIFI_CONNECTION_NAME"
    ssid "$WIFI_SSID"
  )
  [[ -n "$WIFI_INTERFACE" ]] && wifi_add+=(ifname "$WIFI_INTERFACE")
  "${SUDO[@]}" nmcli "${wifi_add[@]}"

  "${SUDO[@]}" nmcli connection modify id "$WIFI_CONNECTION_NAME" \
    connection.autoconnect yes \
    connection.autoconnect-priority 0 \
    802-11-wireless.mode infrastructure \
    802-11-wireless.powersave 2 \
    802-11-wireless-security.key-mgmt wpa-psk \
    802-11-wireless-security.psk "$wifi_password" \
    ipv4.method auto \
    ipv4.route-metric 600 \
    ipv6.method auto \
    ipv6.route-metric 600

  # Prefer every existing wired profile whenever a cable is connected. Wi-Fi
  # remains connected/available and becomes the default route when LAN vanishes.
  while IFS=: read -r wired_uuid wired_type; do
    [[ "$wired_type" == "802-3-ethernet" ]] || continue
    "${SUDO[@]}" nmcli connection modify uuid "$wired_uuid" \
      connection.autoconnect yes \
      ipv4.route-metric 100 \
      ipv6.route-metric 100 || true
  done < <("${SUDO[@]}" nmcli -t -f UUID,TYPE connection show)

  "${SUDO[@]}" nmcli connection reload
  "${SUDO[@]}" nmcli -f NAME,TYPE,AUTOCONNECT connection show id "$WIFI_CONNECTION_NAME"
  unset wifi_password
fi

"${SUDO[@]}" install -d -m 0700 /var/lib/nix-backup
if $ARM_AFTER_INSTALL; then
  log "Arming automatic backup for the next boot"
  "${SUDO[@]}" touch "$ARM_FILE"
  "${SUDO[@]}" chmod 0600 "$ARM_FILE"
else
  log "Leaving automatic backup disarmed for the first network test"
  "${SUDO[@]}" rm -f "$ARM_FILE"
fi

printf '\nInstallation complete.\n'
printf 'Configuration: %s\n' "$CHECKOUT"
printf 'Token: %s (root-only)\n' "$TOKEN_TARGET"
printf 'Configured kernel: Linux 6.6 with r8712u for USB device 13d3:3306.\n'
if [[ -n "$WIFI_SSID" ]]; then
  printf 'Wi-Fi profile: %s (fallback metric 600)\n' "$WIFI_CONNECTION_NAME"
  printf 'Ethernet profiles: preferred metric 100\n'
fi
if $ARM_AFTER_INSTALL; then
  printf 'The next boot will back up all discovered repositories and power off.\n'
else
  printf 'Automatic backup is DISARMED for testing. After Wi-Fi works, run:\n'
  printf '  sudo install -m 0600 /dev/null %s\n' "$ARM_FILE"
  printf 'Then reboot to perform the first automatic backup.\n'
fi
printf '\nThe r8712u driver is loaded only after rebooting into the Linux 6.6 kernel.\n'
printf 'Keep Ethernet connected until the installation has completed successfully.\n'
