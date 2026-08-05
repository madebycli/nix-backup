{ config, lib, pkgs, ... }:

let
  kernelPackages = pkgs.linuxPackages_6_6;
  kernel = kernelPackages.kernel;

  # Last linux-6.6.y source revision immediately before stable commit
  # f12f4c657617 removed drivers/staging/rtl8712 on 2025-12-06.
  r8712uSource = pkgs.fetchFromGitHub {
    owner = "gregkh";
    repo = "linux";
    rev = "2b9719ccad38dffad7dbdd2f39896f723f9b9011";
    hash = "sha256-zZKDLUqGYs0R/Ceb2JfN8QiEaCNKZML4rJMplhAOcmU=";
  };

  r8712uModule = pkgs.stdenv.mkDerivation {
    pname = "r8712u";
    version = "6.6-pre-removal-2b9719c";
    src = r8712uSource;
    sourceRoot = "source/drivers/staging/rtl8712";

    nativeBuildInputs = kernel.moduleBuildDependencies;
    hardeningDisable = [ "pic" ];

    buildPhase = ''
      runHook preBuild
      make -C "${kernel.dev}/lib/modules/${kernel.modDirVersion}/build" \
        M="$PWD" \
        CONFIG_R8712U=m \
        modules
      runHook postBuild
    '';

    installPhase = ''
      runHook preInstall
      install -Dm0644 r8712u.ko \
        "$out/lib/modules/${kernel.modDirVersion}/extra/r8712u.ko"
      runHook postInstall
    '';

    meta = {
      description = "Legacy Realtek RTL8712U/RTL8192SU USB Wi-Fi driver for Linux 6.6";
      license = lib.licenses.gpl2Only;
      platforms = lib.platforms.linux;
    };
  };
in
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

  # Keep the current Linux 6.6 LTS kernel and add only the removed driver as a
  # separately built module. This retains current 6.6 security updates.
  boot.kernelPackages = kernelPackages;
  boot.extraModulePackages = [ r8712uModule ];
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
