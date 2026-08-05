# PLACEHOLDER ONLY.
# scripts/install.sh replaces this tracked file with the machine-generated
# /etc/nixos/hardware-configuration.nix and marks it skip-worktree.
{ modulesPath, ... }:

{
  imports = [ (modulesPath + "/installer/scan/not-detected.nix") ];

  boot.initrd.availableKernelModules = [ ];
  boot.initrd.kernelModules = [ ];
  boot.kernelModules = [ ];
  boot.extraModulePackages = [ ];

  fileSystems."/" = {
    device = "/dev/disk/by-label/nixos";
    fsType = "ext4";
  };

  swapDevices = [ ];
  nixpkgs.hostPlatform = "x86_64-linux";
}
