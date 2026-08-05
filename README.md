# nix-backup

A headless NixOS GitHub-backup appliance for `madebycli`.

After the one-time installation, the machine performs this sequence on every boot:

1. starts NetworkManager and waits for a usable GitHub connection;
2. discovers the current repository list automatically;
3. updates a persistent `git clone --mirror` for every repository;
4. creates a new immutable, UTC-dated snapshot for every repository;
5. exports GitHub metadata, Pull Requests, Issues, Discussions, Actions data, logs, artifacts, releases, and assets where the API permits it;
6. writes manifests and SHA-256 checksums;
7. commits a success/partial/failure JSON status into this repository;
8. refreshes this repository's own Git snapshot so the status commit is included;
9. powers the computer off.

No repository list is hard-coded. A newly created repository is discovered on the next boot. Existing snapshots are never deleted automatically.

## Important guarantee boundary

The Git portion is designed for an exact recovery of normal branches, tags, notes, commits, trees, blobs, and Git LFS objects. GitHub's platform database is different: secret values cannot be read back, expired Actions artifacts/logs no longer exist, and old PR/Issue IDs, timestamps, authorship, review state, and merge UI cannot be recreated byte-for-byte through GitHub's public APIs. The project exports as much readable metadata as possible so a person or AI can reconstruct the surrounding project state, but GitHub itself does not expose a true full-account restore API.

See [docs/RESTORE.md](docs/RESTORE.md) for exact recovery boundaries.

## Backup layout

Default root:

```text
/var/lib/nix-backup/data/
├── mirrors/
│   └── OWNER/REPO.git/                 # newest persistent bare mirror
├── repos/
│   └── OWNER/REPO/
│       ├── latest -> snapshots/<UTC timestamp>
│       └── snapshots/
│           └── 2026-08-05T01-23-45Z/
│               ├── manifest.json
│               ├── SHA256SUMS
│               ├── git/
│               │   ├── repository.bundle.zst
│               │   ├── lfs-objects.tar.zst
│               │   ├── refs.txt
│               │   └── fsck.txt
│               ├── metadata/
│               │   ├── repository.json
│               │   ├── branches.json
│               │   ├── pulls/
│               │   ├── issues.json
│               │   ├── discussions.json
│               │   ├── actions/
│               │   ├── rulesets/
│               │   └── security/
│               ├── binaries/
│               │   ├── actions/logs/
│               │   ├── actions/artifacts/
│               │   └── releases/
│               └── wiki/
└── runs/
    └── <UTC timestamp>/
        ├── backup.log
        ├── repositories.json
        ├── status.json
        ├── manifest.json
        └── SHA256SUMS
```

The snapshot format intentionally uses Git bundles and Zstandard instead of source-code ZIPs. A ZIP of the default branch does not contain the complete commit graph or all refs.

## One-time preparation

Install a minimal, bootable NixOS 26.05 system on the backup computer first. The graphical installer is fine. During that one-time setup:

- use Ethernet, or connect to Wi-Fi temporarily;
- let NixOS generate `/etc/nixos/hardware-configuration.nix`;
- confirm the machine boots from its own disk;
- create a GitHub token as described in [docs/TOKEN.md](docs/TOKEN.md).

The installer detects UEFI automatically. Legacy BIOS requires the target disk explicitly.

## Install

From the installed NixOS system:

```bash
nix run github:madebycli/nix-backup#install
```

The installer:

- clones this repository into `/etc/nixos/nix-backup`;
- copies the current machine's `/etc/nixos/hardware-configuration.nix` over the tracked placeholder;
- writes a machine-local boot-loader file;
- stores the GitHub token at `/var/lib/nix-backup/secrets/github-token` with mode `0600`;
- builds and switches to `.#github-vault`;
- arms the service only after the switch succeeds.

The installation step needs root privileges and therefore uses `sudo`. Later boots require no login, terminal, monitor, or sudo prompt.

### Non-interactive token file

```bash
nix run github:madebycli/nix-backup#install -- \
  --token-file /path/to/github-token \
  --yes
```

Delete the original token file afterward if it was only a transfer copy.

### Configure persistent Wi-Fi during installation

The machine still needs temporary Internet access to download the installer. To create an autoconnect NetworkManager profile as part of the switch:

```bash
printf '%s' 'YOUR_WIFI_PASSWORD' > /tmp/wifi-password
chmod 600 /tmp/wifi-password

nix run github:madebycli/nix-backup#install -- \
  --token-file /path/to/github-token \
  --wifi-ssid 'YOUR_SSID' \
  --wifi-password-file /tmp/wifi-password \
  --yes

rm -f /tmp/wifi-password
```

An optional interface can be supplied with `--wifi-interface wlp2s0`.

### Legacy BIOS

```bash
nix run github:madebycli/nix-backup#install -- \
  --bios-disk /dev/sda
```

Do not guess the BIOS disk. Verify it with `lsblk` first.

## First unattended test

After installation, shut the computer down and turn it on normally. A successful run creates:

```text
status/latest/github-vault.json
status/history/github-vault/<UTC timestamp>.json
```

in this GitHub repository and then powers off.

For a manual systemd test:

```bash
sudo systemctl start github-backup.service
```

That command also powers the machine off when the configured success/failure policy triggers.

To run only the backup program while keeping the machine on:

```bash
sudo github-backup
```

## Logs and diagnosis

Local run logs:

```bash
sudo find /var/lib/nix-backup/data/runs -maxdepth 2 -name backup.log -print
```

Systemd journal from the previous boot:

```bash
sudo journalctl -b -1 -u github-backup.service
```

Temporarily stop automatic boot backups:

```bash
sudo rm /var/lib/nix-backup/armed
```

Re-enable them:

```bash
sudo touch /var/lib/nix-backup/armed
sudo chmod 600 /var/lib/nix-backup/armed
```

## Updates

Configuration updates are explicit and safe by default:

```bash
sudo nix-backup-update
```

This fast-forwards `/etc/nixos/nix-backup`, checks the flake, builds the new system, asks for confirmation, and then switches. To update the pinned Nixpkgs revision too:

```bash
sudo nix-backup-update --flake-update
```

The boot backup does not silently rewrite the operating-system configuration.

## Restore a repository

Restore the latest snapshot to an empty repository of the same name:

```bash
sudo nix-backup-restore madebycli/REPOSITORY
```

Restore into a newly created private repository:

```bash
sudo nix-backup-restore madebycli/OLD-REPOSITORY \
  --target madebycli/RESTORED-REPOSITORY \
  --create \
  --visibility private
```

Read [docs/RESTORE.md](docs/RESTORE.md) before restoring over an existing repository.

## Storage policy

No automatic retention or deletion is enabled. This matches the goal of keeping every dated backup, but a 320 GB disk will eventually fill. Before each repository, the service verifies that at least 10 GiB remain. If the threshold is crossed, it stops creating further snapshots, records the failure locally, attempts to write the GitHub status, and follows the configured shutdown policy.

Change the storage path or thresholds in `hosts/github-vault/default.nix`.
