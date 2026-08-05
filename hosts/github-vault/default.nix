{ config, lib, pkgs, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot-loader.nix
    ../../modules/github-backup.nix
  ];

  networking.hostName = "github-vault";
  networking.networkmanager = {
    enable = true;
    # The legacy r8712u driver uses Wireless Extensions; wpa_supplicant is the
    # most compatible NetworkManager backend for this adapter.
    wifi.backend = "wpa_supplicant";
  };
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

  # USB device 13d3:3306 is a Realtek RTL8191SU. Its in-tree r8712u staging
  # driver still exists in Linux 6.6 but was removed from later 6.12 updates.
  # Keep this appliance on the supported 6.6 LTS kernel while this adapter is
  # in use. Ethernet remains available and is preferred by route metric.
  boot.kernelPackages = pkgs.linuxPackages_6_6;
  boot.kernelModules = [ "r8712u" ];

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

  system.stateVersion = "26.05";
}
