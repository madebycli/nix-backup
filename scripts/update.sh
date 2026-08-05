#!/usr/bin/env bash
set -Eeuo pipefail

: "${NIX_BACKUP_CHECKOUT:=/etc/nixos/nix-backup}"
: "${NIX_BACKUP_PROFILE:=github-vault}"

UPDATE_FLAKE=false
NON_INTERACTIVE=false

usage() {
  cat <<'USAGE'
Update the installed nix-backup configuration from GitHub.

Usage:
  sudo nix-backup-update [options]

Options:
  --flake-update       Also update flake.lock before rebuilding.
  --non-interactive    Do not ask for confirmation.
  -h, --help           Show this help.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

while (($#)); do
  case "$1" in
    --flake-update) UPDATE_FLAKE=true ;;
    --non-interactive) NON_INTERACTIVE=true ;;
    -h|--help) usage; exit 0 ;;
    *) die "unknown option: $1" ;;
  esac
  shift
done

[[ $EUID -eq 0 ]] || die "run this command with sudo"
[[ -d "$NIX_BACKUP_CHECKOUT/.git" ]] || die "checkout missing: $NIX_BACKUP_CHECKOUT"

cd "$NIX_BACKUP_CHECKOUT"
[[ -z "$(git status --porcelain --untracked-files=no)" ]] \
  || die "tracked local changes exist; refusing to overwrite them"

printf '==> Fetching configuration updates\n'
git fetch origin main
git merge --ff-only origin/main

if $UPDATE_FLAKE; then
  printf '==> Updating flake inputs\n'
  nix flake update
fi

printf '==> Checking flake\n'
nix flake check --no-build
printf '==> Building NixOS configuration\n'
nixos-rebuild build --flake ".#${NIX_BACKUP_PROFILE}"

if ! $NON_INTERACTIVE; then
  printf 'Activate the new configuration? [y/N] '
  read -r answer
  case "$answer" in
    y|Y|yes|YES|j|J|ja|JA) ;;
    *) printf 'Build completed but was not activated.\n'; exit 0 ;;
  esac
fi

printf '==> Activating configuration\n'
nixos-rebuild switch --flake ".#${NIX_BACKUP_PROFILE}"
printf 'Update complete. The next boot uses the new backup configuration.\n'
