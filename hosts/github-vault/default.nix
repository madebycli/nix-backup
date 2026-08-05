{ config, lib, ... }:

{
  imports = [
    ./hardware-configuration.nix
    ./boot-loader.nix
    ../../modules/github-backup.nix
  ];

  networking.hostName = "github-vault";
  networking.networkmanager.enable = true;
  networking.firewall.enable = true;

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

  # SSH is available for diagnosis, but password and keyboard-interactive login
  # are disabled. Add an authorized key for an existing user before relying on it.
  services.openssh = {
    enable = true;
    openFirewall = true;
    settings = {
      PasswordAuthentication = false;
      KbdInteractiveAuthentication = false;
      PermitRootLogin = "prohibit-password";
    };
  };

  services.journald.extraConfig = ''
    Storage=persistent
    SystemMaxUse=2G
    MaxRetentionSec=6month
  '';

  services.fstrim.enable = true;
  hardware.enableRedistributableFirmware = true;
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
