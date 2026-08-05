#!/usr/bin/env bash
set -Eeuo pipefail
umask 077

: "${BACKUP_ROOT:=/var/lib/nix-backup/data}"
: "${GH_TOKEN_FILE:=/var/lib/nix-backup/secrets/github-token}"

SOURCE_REPOSITORY=""
TARGET_REPOSITORY=""
SNAPSHOT=""
CREATE_REPOSITORY=false
FORCE=false
VISIBILITY=""

usage() {
  cat <<'USAGE'
Restore the Git data of one repository from a nix-backup snapshot.

Usage:
  nix-backup-restore OWNER/REPO [options]

Options:
  --snapshot PATH       Explicit snapshot directory. Default: latest snapshot.
  --target OWNER/REPO   Destination repository. Default: same OWNER/REPO.
  --create              Create the destination repository when it does not exist.
  --visibility VALUE    public, private, or internal when using --create.
  --force               Allow pushing into a non-empty destination repository.
  -h, --help            Show this help.

The script restores normal Git branches, tags, notes, commits, and Git LFS
objects. GitHub-generated refs under refs/pull/* remain in the local bundle but
cannot be pushed back into GitHub's protected pull-request namespace.
USAGE
}

die() {
  printf 'Error: %s\n' "$*" >&2
  exit 1
}

log() {
  printf '==> %s\n' "$*"
}

while (($#)); do
  case "$1" in
    --snapshot)
      [[ $# -ge 2 ]] || die "--snapshot requires a path"
      SNAPSHOT="$2"
      shift 2
      ;;
    --target)
      [[ $# -ge 2 ]] || die "--target requires OWNER/REPO"
      TARGET_REPOSITORY="$2"
      shift 2
      ;;
    --create)
      CREATE_REPOSITORY=true
      shift
      ;;
    --visibility)
      [[ $# -ge 2 ]] || die "--visibility requires public, private, or internal"
      VISIBILITY="$2"
      shift 2
      ;;
    --force)
      FORCE=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    --*)
      die "unknown option: $1"
      ;;
    *)
      [[ -z "$SOURCE_REPOSITORY" ]] || die "only one source repository may be specified"
      SOURCE_REPOSITORY="$1"
      shift
      ;;
  esac
done

[[ "$SOURCE_REPOSITORY" == */* ]] || {
  usage
  die "source repository must be OWNER/REPO"
}

TARGET_REPOSITORY="${TARGET_REPOSITORY:-$SOURCE_REPOSITORY}"
[[ "$TARGET_REPOSITORY" == */* ]] || die "target repository must be OWNER/REPO"

source_owner="${SOURCE_REPOSITORY%%/*}"
source_name="${SOURCE_REPOSITORY#*/}"
repo_backup_root="${BACKUP_ROOT}/repos/${source_owner}/${source_name}"

if [[ -z "$SNAPSHOT" ]]; then
  if [[ -L "$repo_backup_root/latest" ]]; then
    SNAPSHOT="$(readlink -f "$repo_backup_root/latest")"
  else
    SNAPSHOT="$(find "$repo_backup_root/snapshots" -mindepth 1 -maxdepth 1 -type d -printf '%p\n' 2>/dev/null | sort | tail -n1)"
  fi
fi

[[ -n "$SNAPSHOT" && -d "$SNAPSHOT" ]] || die "snapshot not found"
[[ -f "$SNAPSHOT/manifest.json" ]] || die "snapshot manifest missing: $SNAPSHOT/manifest.json"

if [[ -f "$SNAPSHOT/SHA256SUMS" ]]; then
  log "Verifying snapshot checksums"
  (cd "$SNAPSHOT" && sha256sum -c SHA256SUMS)
fi

if [[ -s "$GH_TOKEN_FILE" ]]; then
  export GH_TOKEN="$(tr -d '\r\n' < "$GH_TOKEN_FILE")"
elif [[ -z "${GH_TOKEN:-}" ]]; then
  die "GitHub token missing: $GH_TOKEN_FILE (or export GH_TOKEN)"
fi
export GITHUB_TOKEN="$GH_TOKEN"
export GIT_TERMINAL_PROMPT=0
export GH_PAGER=cat

readonly GIT_CREDENTIAL_HELPER='!f() { if [ "$1" = get ]; then echo username=x-access-token; echo "password=$GH_TOKEN"; fi; }; f'
git_auth() {
  git -c credential.helper= -c "credential.helper=${GIT_CREDENTIAL_HELPER}" "$@"
}

if ! gh repo view "$TARGET_REPOSITORY" >/dev/null 2>&1; then
  $CREATE_REPOSITORY || die "target repository does not exist; use --create"
  if [[ -z "$VISIBILITY" ]]; then
    VISIBILITY="$(jq -r '.visibility // "private"' "$SNAPSHOT/manifest.json")"
  fi
  case "$VISIBILITY" in
    public|private|internal) ;;
    *) die "invalid visibility: $VISIBILITY" ;;
  esac
  log "Creating $TARGET_REPOSITORY as $VISIBILITY"
  gh repo create "$TARGET_REPOSITORY" "--$VISIBILITY"
fi

if ! $FORCE; then
  remote_ref_count="$(gh api "/repos/${TARGET_REPOSITORY}/git/matching-refs/heads/" --jq 'length' 2>/dev/null || printf '0')"
  [[ "$remote_ref_count" == "0" ]] || die "target has branches; use --force after checking the destination"
fi

work_dir="$(mktemp -d)"
trap 'rm -rf "$work_dir"' EXIT
restore_mirror="$work_dir/restore.git"

if [[ -f "$SNAPSHOT/git/repository.bundle.zst" ]]; then
  log "Decompressing Git bundle"
  zstd -d -q "$SNAPSHOT/git/repository.bundle.zst" -o "$work_dir/repository.bundle"
  git init --bare -q "$work_dir/verify.git"
  git -C "$work_dir/verify.git" bundle verify "$work_dir/repository.bundle"
  git clone --mirror "$work_dir/repository.bundle" "$restore_mirror"
elif [[ -f "$SNAPSHOT/git/empty-mirror.tar.zst" ]]; then
  log "Restoring empty repository mirror"
  mkdir -p "$work_dir/empty"
  zstd -dc "$SNAPSHOT/git/empty-mirror.tar.zst" | tar -xf - -C "$work_dir/empty"
  extracted="$(find "$work_dir/empty" -mindepth 1 -maxdepth 1 -type d | head -n1)"
  [[ -n "$extracted" ]] || die "empty mirror archive is invalid"
  cp -a "$extracted" "$restore_mirror"
else
  die "snapshot contains no Git bundle or empty mirror"
fi

if [[ -f "$SNAPSHOT/git/lfs-objects.tar.zst" ]]; then
  log "Restoring Git LFS object store"
  zstd -dc "$SNAPSHOT/git/lfs-objects.tar.zst" | tar -xf - -C "$restore_mirror"
fi

remote_url="https://github.com/${TARGET_REPOSITORY}.git"
git -C "$restore_mirror" remote remove origin 2>/dev/null || true
git -C "$restore_mirror" remote add target "$remote_url"

refspecs=()
for namespace in heads tags notes replace; do
  if git -C "$restore_mirror" for-each-ref --format='%(refname)' "refs/${namespace}" | grep -q .; then
    refspecs+=("+refs/${namespace}/*:refs/${namespace}/*")
  fi
done

if ((${#refspecs[@]})); then
  log "Pushing branches, tags, notes, and replace refs"
  git_auth -C "$restore_mirror" push target "${refspecs[@]}"
else
  log "Repository is empty; no Git refs need to be pushed"
fi

if [[ -d "$restore_mirror/lfs/objects" ]] && find "$restore_mirror/lfs/objects" -type f -print -quit | grep -q .; then
  log "Pushing all Git LFS objects"
  git_auth -C "$restore_mirror" lfs push --all target
fi

printf '\nGit restore complete.\nSource snapshot: %s\nDestination: %s\n' "$SNAPSHOT" "$TARGET_REPOSITORY"
printf 'Saved GitHub metadata remains available at: %s/metadata\n' "$SNAPSHOT"
printf 'See docs/RESTORE.md for platform metadata limitations and reconstruction steps.\n'
