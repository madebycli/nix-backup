{
  description = "Headless NixOS appliance that backs up GitHub repositories and powers off";

  inputs = {
    nixpkgs.url = "github:NixOS/nixpkgs/nixos-26.05";
  };

  outputs = { self, nixpkgs }:
    let
      system = "x86_64-linux";
      pkgs = nixpkgs.legacyPackages.${system};

      backupProgram = pkgs.writeShellApplication {
        name = "github-backup";
        inheritPath = true;
        runtimeInputs = with pkgs; [
          bash
          coreutils
          curl
          findutils
          gawk
          git
          git-lfs
          gh
          gnugrep
          gnused
          gnutar
          gzip
          jq
          openssh
          rsync
          util-linux
          zip
          unzip
          zstd
        ];
        text = builtins.readFile ./scripts/backup.sh;
        checkPhase = ''
          ${pkgs.bash}/bin/bash -n "$target"
        '';
      };

      restoreProgram = pkgs.writeShellApplication {
        name = "nix-backup-restore";
        inheritPath = true;
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          git
          git-lfs
          gh
          gnugrep
          gnutar
          jq
          zstd
        ];
        text = builtins.readFile ./scripts/restore-repo.sh;
        checkPhase = ''
          ${pkgs.bash}/bin/bash -n "$target"
        '';
      };

      updateProgram = pkgs.writeShellApplication {
        name = "nix-backup-update";
        inheritPath = true;
        runtimeInputs = with pkgs; [
          coreutils
          git
          nix
          nixos-rebuild
        ];
        text = builtins.readFile ./scripts/update.sh;
        checkPhase = ''
          ${pkgs.bash}/bin/bash -n "$target"
        '';
      };

      installProgram = pkgs.writeShellApplication {
        name = "nix-backup-install";
        inheritPath = true;
        runtimeInputs = with pkgs; [
          coreutils
          findutils
          git
          gh
          gnugrep
          gnused
          jq
          nix
          nixos-rebuild
          util-linux
        ];
        text = builtins.readFile ./scripts/install.sh;
        checkPhase = ''
          ${pkgs.bash}/bin/bash -n "$target"
        '';
      };
    in
    {
      nixosConfigurations.github-vault = nixpkgs.lib.nixosSystem {
        inherit system;
        specialArgs = {
          inherit backupProgram restoreProgram updateProgram;
        };
        modules = [ ./hosts/github-vault ];
      };

      packages.${system} = {
        default = backupProgram;
        backup = backupProgram;
        restore = restoreProgram;
        update = updateProgram;
        install = installProgram;
      };

      apps.${system} = {
        default = {
          type = "app";
          program = "${backupProgram}/bin/github-backup";
        };
        backup = {
          type = "app";
          program = "${backupProgram}/bin/github-backup";
        };
        restore = {
          type = "app";
          program = "${restoreProgram}/bin/nix-backup-restore";
        };
        update = {
          type = "app";
          program = "${updateProgram}/bin/nix-backup-update";
        };
        install = {
          type = "app";
          program = "${installProgram}/bin/nix-backup-install";
        };
      };

      formatter.${system} = pkgs.nixfmt-rfc-style;
    };
}
