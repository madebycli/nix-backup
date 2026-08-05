#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

readonly REPO_URL="https://github.com/madebycli/nix-backup.git"
readonly PROFILE="github-vault"
readonly HARDWARE_SOURCE="/etc/nixos/hardware-configuration.nix"
readonly TOKEN_TARGET="/var/lib/nix-backup/secrets/github-token"
readonly ARM_FILE="/var/lib/nix-backup/armed"

CHECKOUT="/etc/nixos/nix-backup"
TOKEN_SOURCE=""
BIOS_DISK=""
WIFI_SSID=""
WIFI_PASSWORD_FILE=""
WIFI_INTERFACE=""
AUTO_YES=false

usage() {
  cat <<'USAGE'
Install nix-backup on an already bootable minimal NixOS installation.

Recommended command:
  nix run github:madebycli/nix-backup#install

Options:
  --checkout PATH    Configuration checkout. Default: /etc/nixos/nix-backup
  --token-file PATH  Read the GitHub token from this file instead of prompting.
  --bios-disk PATH      GRUB installation disk for legacy BIOS, for example /dev/sda.
  --wifi-ssid SSID      Create/refresh a persistent NetworkManager Wi-Fi profile.
  --wifi-password-file  File containing the Wi-Fi password (used with --wifi-ssid).
  --wifi-interface IF   Optional wireless interface, for example wlp2s0.
  --yes, -y             Build and switch without a confirmation prompt.
  -h, --help         Show this help.

On UEFI systems the installer configures systemd-boot automatically. On legacy
BIOS systems --bios-disk is required. The currently generated NixOS hardware
configuration is copied into the cloned repository before the rebuild.
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

# Prevent a newly enabled unit from starting during nixos-rebuild switch. The
# appliance is armed only after the switch has completed successfully.
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
  log "Creating persistent NetworkManager profile for $WIFI_SSID"
  nmcli_args=(device wifi connect "$WIFI_SSID" password "$wifi_password")
  [[ -n "$WIFI_INTERFACE" ]] && nmcli_args+=(ifname "$WIFI_INTERFACE")
  "${SUDO[@]}" nmcli "${nmcli_args[@]}"
  active_wifi_interface="$WIFI_INTERFACE"
  if [[ -z "$active_wifi_interface" ]]; then
    active_wifi_interface="$("${SUDO[@]}" nmcli -t -f DEVICE,TYPE device | awk -F: '$2=="wifi" {print $1; exit}')"
  fi
  connection_name=""
  if [[ -n "$active_wifi_interface" ]]; then
    connection_name="$("${SUDO[@]}" nmcli -g GENERAL.CONNECTION device show "$active_wifi_interface" 2>/dev/null || true)"
  fi
  if [[ -n "$connection_name" && "$connection_name" != "--" ]]; then
    "${SUDO[@]}" nmcli connection modify "$connection_name" connection.autoconnect yes
  fi
  unset wifi_password
fi

log "Arming automatic backup for the next boot"
"${SUDO[@]}" install -d -m 0700 /var/lib/nix-backup
"${SUDO[@]}" touch "$ARM_FILE"
"${SUDO[@]}" chmod 0600 "$ARM_FILE"

printf '\nInstallation complete.\n'
printf 'Configuration: %s\n' "$CHECKOUT"
printf 'Token: %s (root-only)\n' "$TOKEN_TARGET"
printf 'The next boot will wait for the network, back up all discovered repositories,\n'
printf 'write status JSON to madebycli/nix-backup, and power off.\n'
printf '\nBefore testing unattended Wi-Fi, verify that NetworkManager has a saved autoconnect profile:\n'
printf '  nmcli connection show\n'
printf '\nManual backup test (this will power off when started through systemd):\n'
printf '  sudo systemctl start github-backup.service\n'
