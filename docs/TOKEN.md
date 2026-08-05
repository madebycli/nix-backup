# GitHub token

The backup service needs one GitHub credential for four jobs:

1. discover private and public repositories;
2. clone/fetch Git data and Git LFS objects;
3. read Issues, Pull Requests, Actions, rules, releases, and other metadata;
4. commit status JSON into `madebycli/nix-backup`.

## Recommended token

For this personal appliance, a classic Personal Access Token is the simplest way to make future repositories appear automatically. Use the narrowest scopes compatible with your account:

- `repo` for private repositories and repository metadata;
- `read:org` when organization repositories or team metadata must be included.

A public-only account can use a narrower public-repository token, but the status repository still requires Contents write access.

A fine-grained token can also work. It needs access to every repository being backed up, read access to Contents, Actions, Issues, Pull Requests, Metadata, and relevant administration/security data, plus Contents write access to `madebycli/nix-backup`. Confirm how the token handles repositories created after the token was issued.

## Storage

The installer writes the token to:

```text
/var/lib/nix-backup/secrets/github-token
```

Permissions are `root:root` and `0600`. The token is never placed in the Nix store, repository, backup manifests, Git remotes, or status JSON.

Check permissions:

```bash
sudo stat /var/lib/nix-backup/secrets/github-token
```

Rotate the token:

```bash
sudo install -m 0600 /path/to/new-token \
  /var/lib/nix-backup/secrets/github-token
```

Then run a test while keeping the machine on:

```bash
sudo github-backup
```

## Information GitHub never returns

The API exposes secret names and selected metadata, but not secret values. This includes GitHub Actions secrets, environment secrets, Dependabot secrets, webhook secrets, private deploy credentials, and external service credentials. Keep those in a separate encrypted secret backup.
