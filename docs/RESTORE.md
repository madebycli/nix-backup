# Restore guide

## What can be restored exactly

The compressed Git bundle contains the repository's reachable Git object graph and advertised refs at backup time. The restore tool pushes normal:

- branches under `refs/heads/*`;
- tags under `refs/tags/*`;
- Git notes under `refs/notes/*`;
- replace refs under `refs/replace/*`;
- all corresponding commits, trees, and blobs.

`lfs-objects.tar.zst` contains Git LFS objects fetched with `git lfs fetch --all`; the restore tool uploads them with `git lfs push --all`.

A repository restored from these objects has the same Git commit SHAs, history, branches, tags, and file contents. Commit SHAs remain unchanged because the commit objects are unchanged.

## GitHub-generated refs

The bundle can contain `refs/pull/<number>/head` and `refs/pull/<number>/merge`. GitHub owns that namespace and rejects attempts to push it. These refs remain readable from the local bundle for forensic recovery, but cannot be recreated directly as GitHub PR refs.

Inspect all saved refs:

```bash
git bundle list-heads repository.bundle
```

## Platform metadata

The `metadata/` directory exports the readable state needed for reconstruction:

- repository settings and topics;
- branches, protections, rulesets, environments, deploy keys, collaborators, and teams where permitted;
- Pull Requests, comments, reviews, commits, changed files, diffs, and patches;
- Issues, labels, milestones, comments, and events;
- Discussions and up to 100 nested comments/replies per discussion level;
- workflow definitions through Git, workflow/run/job metadata, retained logs, and non-expired artifacts;
- releases and retained release assets;
- security alert metadata where token permissions allow it;
- Wiki Git history where a Wiki repository exists.

This metadata is intentionally plain JSON so it can be inspected or supplied to an AI.

## What cannot be restored identically

GitHub does not provide an account-level import that preserves its internal database identifiers. Recreating an Issue or PR produces a new number and new creation time. Comments and reviews are attributed to the account performing the restore, not necessarily the original author. Merged-state UI, review approvals, notification history, stars, watchers, traffic data, deleted forks, and some security/audit records cannot be restored exactly.

GitHub also does not return secret values. Expired Actions logs/artifacts and deleted release assets cannot be downloaded after GitHub removes them.

## Safe restore procedure

1. Choose a snapshot and verify `SHA256SUMS`.
2. Restore into a new empty repository first.
3. Compare refs and commit counts.
4. Verify LFS files by cloning the restored repository normally.
5. Recreate repository settings, rules, labels, releases, and other platform objects from JSON only after reviewing them.
6. Re-enter secrets from a separate encrypted secret store.
7. Change the default branch and branch protections last.

Example:

```bash
sudo nix-backup-restore madebycli/PROJECT \
  --target madebycli/PROJECT-RECOVERED \
  --create \
  --visibility private
```

Restore a specific snapshot:

```bash
sudo nix-backup-restore madebycli/PROJECT \
  --snapshot /var/lib/nix-backup/data/repos/madebycli/PROJECT/snapshots/2026-08-05T01-23-45Z \
  --target madebycli/PROJECT-RECOVERED \
  --create \
  --visibility private
```

Only use `--force` after verifying that overwriting refs in the destination is intended.
