{ config, lib, pkgs, backupProgram, restoreProgram, updateProgram, ... }:

let
  cfg = config.services.githubBackup;
  boolString = value: if value then "true" else "false";

  usbCopyProgram = pkgs.writeShellApplication {
    name = "github-backup-usb-copy";
    runtimeInputs = [
      pkgs.coreutils
      pkgs.rsync
      pkgs.systemd
      pkgs.util-linux
    ];
    text = ''
      set -Eeuo pipefail

      readonly label=${lib.escapeShellArg cfg.usbCopy.label}
      readonly source_root=${lib.escapeShellArg cfg.storageRoot}
      readonly mount_point=${lib.escapeShellArg cfg.usbCopy.mountPoint}
      readonly destination_name=${lib.escapeShellArg cfg.usbCopy.destination}
      readonly device="/dev/disk/by-label/$label"

      if [[ ! -e "$device" ]]; then
        echo "Dedicated USB backup drive ($label) is not attached; skipping second copy."
        exit 0
      fi

      echo "Dedicated USB backup drive detected: $device"
      automount_unit="$(systemd-escape --path --suffix=automount "$mount_point")"
      mount_unit="$(systemd-escape --path --suffix=mount "$mount_point")"
      systemctl start "$automount_unit"

      if ! timeout 20 ls -A "$mount_point" >/dev/null 2>&1; then
        echo "Could not activate USB mount at $mount_point" >&2
        exit 1
      fi
      if ! mountpoint -q "$mount_point"; then
        echo "USB drive exists but is not mounted at $mount_point" >&2
        exit 1
      fi

      destination="$mount_point/$destination_name"
      install -d -m 0700 "$destination"
      echo "Mirroring $source_root to $destination"
      rsync \
        -aHAX \
        --numeric-ids \
        --delete \
        --delete-delay \
        --partial \
        --human-readable \
        --stats \
        "$source_root/" \
        "$destination/"
      sync -f "$destination"
      echo "USB mirror completed successfully."

      systemctl stop "$mount_unit" || true
    '';
  };
in
{
  options.services.githubBackup = {
    enable = lib.mkEnableOption "automatic full GitHub backup on boot";

    owner = lib.mkOption {
      type = lib.types.str;
      default = "madebycli";
      description = "GitHub user or organization whose repositories are backed up.";
    };

    scope = lib.mkOption {
      type = lib.types.enum [ "owner" "accessible" ];
      default = "owner";
      description = ''
        owner backs up repositories owned by services.githubBackup.owner.
        accessible backs up every repository visible to the token, including
        organization and collaborator repositories.
      '';
    };

    storageRoot = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nix-backup/data";
      description = "Persistent directory containing mirrors, snapshots, run logs, and manifests.";
    };

    tokenFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nix-backup/secrets/github-token";
      description = "Root-readable file containing the GitHub token. Never place this file in the Nix store.";
    };

    armFile = lib.mkOption {
      type = lib.types.str;
      default = "/var/lib/nix-backup/armed";
      description = "The boot service runs only while this file exists.";
    };

    statusRepository = lib.mkOption {
      type = lib.types.str;
      default = "madebycli/nix-backup";
      description = "Repository receiving status/history and status/latest JSON files.";
    };

    statusBranch = lib.mkOption {
      type = lib.types.str;
      default = "main";
      description = "Branch used for remote status commits.";
    };

    includeActionLogs = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Download all workflow-run logs that GitHub still retains.";
    };

    includeArtifacts = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Download all non-expired GitHub Actions artifacts.";
    };

    includeReleaseAssets = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Download GitHub release assets.";
    };

    minimumFreeGiB = lib.mkOption {
      type = lib.types.ints.positive;
      default = 10;
      description = "Abort before starting another repository when less space is available.";
    };

    networkWaitSeconds = lib.mkOption {
      type = lib.types.ints.positive;
      default = 600;
      description = "Maximum time to wait for GitHub connectivity and valid authentication.";
    };

    shutdownAfterBackup = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Power off after a completely successful boot backup.";
    };

    shutdownOnFailure = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = "Also power off after a failed or partial boot backup.";
    };

    usbCopy = {
      enable = lib.mkEnableOption "a second complete copy on a dedicated ext4 USB drive";

      label = lib.mkOption {
        type = lib.types.str;
        default = "NIX_BACKUP";
        description = "Filesystem label of the dedicated ext4 USB backup drive.";
      };

      mountPoint = lib.mkOption {
        type = lib.types.str;
        default = "/mnt/nix-backup-usb";
        description = "Automatic mount point for the dedicated USB backup drive.";
      };

      destination = lib.mkOption {
        type = lib.types.str;
        default = "github-vault";
        description = "Directory on the USB drive receiving the complete storageRoot mirror.";
      };
    };
  };

  config = lib.mkIf cfg.enable {
    assertions = [
      {
        assertion = builtins.match "[^/]+/[^/]+" cfg.statusRepository != null;
        message = "services.githubBackup.statusRepository must be OWNER/REPO";
      }
      {
        assertion = cfg.storageRoot != "/";
        message = "services.githubBackup.storageRoot must not be /";
      }
      {
        assertion = !cfg.usbCopy.enable || builtins.match "[A-Za-z0-9._-]+" cfg.usbCopy.label != null;
        message = "services.githubBackup.usbCopy.label may contain only letters, digits, dot, underscore, and dash";
      }
      {
        assertion = !cfg.usbCopy.enable || builtins.match "/.+" cfg.usbCopy.mountPoint != null;
        message = "services.githubBackup.usbCopy.mountPoint must be an absolute path other than /";
      }
      {
        assertion = !cfg.usbCopy.enable || builtins.match "[A-Za-z0-9._-]+" cfg.usbCopy.destination != null;
        message = "services.githubBackup.usbCopy.destination must be a simple directory name";
      }
    ];

    environment.systemPackages = [
      backupProgram
      restoreProgram
      updateProgram
      pkgs.git
      pkgs.git-lfs
      pkgs.gh
      pkgs.jq
      pkgs.zstd
    ] ++ lib.optionals cfg.usbCopy.enable [
      usbCopyProgram
      pkgs.rsync
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/nix-backup 0700 root root -"
      "d /var/lib/nix-backup/home 0700 root root -"
      "d /var/lib/nix-backup/secrets 0700 root root -"
      "d ${cfg.storageRoot} 0700 root root -"
    ] ++ lib.optionals cfg.usbCopy.enable [
      "d ${cfg.usbCopy.mountPoint} 0700 root root -"
    ];

    fileSystems = lib.mkIf cfg.usbCopy.enable {
      "${cfg.usbCopy.mountPoint}" = {
        device = "/dev/disk/by-label/${cfg.usbCopy.label}";
        fsType = "ext4";
        options = [
          "nofail"
          "noatime"
          "x-systemd.automount"
          "x-systemd.device-timeout=5s"
          "x-systemd.idle-timeout=60s"
        ];
      };
    };

    systemd.services.github-backup = {
      description = "Create a complete versioned GitHub backup";
      documentation = [ "https://github.com/madebycli/nix-backup" ];
      wantedBy = [ "multi-user.target" ];
      wants = [ "network-online.target" ];
      after = [
        "local-fs.target"
        "network-online.target"
        "NetworkManager-wait-online.service"
      ];

      unitConfig = {
        ConditionPathExists = [ cfg.armFile cfg.tokenFile ];
        RequiresMountsFor = cfg.storageRoot;
        StartLimitIntervalSec = 0;
      }
      // lib.optionalAttrs cfg.usbCopy.enable {
        OnSuccess = "github-backup-usb-copy.service";
      }
      // lib.optionalAttrs (!cfg.usbCopy.enable && cfg.shutdownAfterBackup) {
        OnSuccess = "github-backup-poweroff.service";
      }
      // lib.optionalAttrs cfg.shutdownOnFailure {
        OnFailure = "github-backup-poweroff.service";
      };

      environment = {
        HOME = "/var/lib/nix-backup/home";
        BACKUP_OWNER = cfg.owner;
        BACKUP_SCOPE = cfg.scope;
        BACKUP_ROOT = cfg.storageRoot;
        GH_TOKEN_FILE = cfg.tokenFile;
        STATUS_REPOSITORY = cfg.statusRepository;
        STATUS_BRANCH = cfg.statusBranch;
        INCLUDE_ACTION_LOGS = boolString cfg.includeActionLogs;
        INCLUDE_ARTIFACTS = boolString cfg.includeArtifacts;
        INCLUDE_RELEASE_ASSETS = boolString cfg.includeReleaseAssets;
        MIN_FREE_GIB = toString cfg.minimumFreeGiB;
        NETWORK_WAIT_SECONDS = toString cfg.networkWaitSeconds;
      };

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = "${backupProgram}/bin/github-backup";
        TimeoutStartSec = "infinity";
        Nice = 10;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ "/var/lib/nix-backup" cfg.storageRoot ];
        RestrictAddressFamilies = [ "AF_UNIX" "AF_INET" "AF_INET6" ];
      };
    };

    systemd.services.github-backup-usb-copy = lib.mkIf cfg.usbCopy.enable {
      description = "Mirror the successful GitHub backup to the dedicated USB drive";
      after = [ "github-backup.service" ];

      unitConfig = lib.optionalAttrs cfg.shutdownAfterBackup {
        OnSuccess = "github-backup-poweroff.service";
      } // lib.optionalAttrs cfg.shutdownOnFailure {
        OnFailure = "github-backup-poweroff.service";
      };

      serviceConfig = {
        Type = "oneshot";
        User = "root";
        Group = "root";
        UMask = "0077";
        ExecStart = "${usbCopyProgram}/bin/github-backup-usb-copy";
        TimeoutStartSec = "infinity";
        Nice = 15;
        IOSchedulingClass = "idle";
        NoNewPrivileges = true;
        PrivateTmp = true;
        ProtectHome = true;
        ProtectSystem = "strict";
        ReadWritePaths = [ cfg.usbCopy.mountPoint ];
      };
    };

    systemd.services.github-backup-poweroff = {
      description = "Power off after the GitHub backup run";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl --no-block poweroff";
      };
    };
  };
}
