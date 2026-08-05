{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot-loader.nix
    ../../modules/github-backup.nix
  ];

  networking.hostName = "github-vault";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

  users.users.xxxxx = {
    isNormalUser = true;
    description = "Backup server administrator";
    home = "/home/xxxxx";
    createHome = true;
    extraGroups = [ "wheel" "networkmanager" ];
    openssh.authorizedKeys.keyFiles = [ ./authorized_keys ];
  };

  services.githubBackup = {
    enable = true;
    owner = "madebycli";
    scope = "owner";
    storageRoot = "/var/lib/nix-backup/data";
    tokenFile = "/var/lib/nix-backup/secrets/github-token";
    statusRepository = "madebycli/nix-backup";
    statusBranch = "main";
    includeActionLogs = true;
    includeArtifacts = true;
    includeReleaseAssets = true;
    minimumFreeGiB = 10;
    networkWaitSeconds = 600;
    shutdownAfterBackup = true;
    shutdownOnFailure = true;
  };

  # SSH is key-only. The installer copies the existing authorized_keys file
  # for user xxxxx into the machine-local placeholder before the first switch.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "no";
    };
  };

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=2G
    MaxRetentionSec=6month
  '';

  services.fstrim.enable = true;

  hardware.enableRedistributableFirmware = true;
  hardware.firmware = [ pkgs.linux-firmware ];
  hardware.cpu.intel.updateMicrocode = lib.mkDefault config.hardware.enableRedistributableFirmware;

  nix = {
    settings = {
      experimental-features = [ "nix-command" "flakes" ];
      auto-optimise-store = true;
    };
    gc.automatic = false;
  };

  time.timeZone = "Europe/Berlin";
  i18n.defaultLocale = "de_DE.UTF-8";
  console.keyMap = "de";

  # Preserve the compatibility baseline of the existing NixOS 25.11 install.
  system.stateVersion = "25.11";
}
