# PLACEHOLDER ONLY.
# scripts/install.sh replaces this with a detected UEFI or explicit BIOS setup.
{ ... }:

{
  boot.loader.systemd-boot.enable = true;
  boot.loader.efi.canTouchEfiVariables = true;
}
