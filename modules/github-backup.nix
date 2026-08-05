{ config, lib, pkgs, backupProgram, restoreProgram, updateProgram, ... }:

let
  cfg = config.services.githubBackup;
  boolString = value: if value then "true" else "false";
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
    ];

    systemd.tmpfiles.rules = [
      "d /var/lib/nix-backup 0700 root root -"
      "d /var/lib/nix-backup/home 0700 root root -"
      "d /var/lib/nix-backup/secrets 0700 root root -"
      "d ${cfg.storageRoot} 0700 root root -"
    ];

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
      // lib.optionalAttrs cfg.shutdownAfterBackup {
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

    systemd.services.github-backup-poweroff = {
      description = "Power off after the GitHub backup run";
      serviceConfig = {
        Type = "oneshot";
        ExecStart = "${pkgs.systemd}/bin/systemctl --no-block poweroff";
      };
    };
  };
}
