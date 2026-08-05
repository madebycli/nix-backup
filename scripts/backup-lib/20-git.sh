create_git_snapshot() {
  local full_name="$1"
  local clone_url="$2"
  local snapshot_dir="$3"
  local mirror_dir="$4"
  local git_dir="$snapshot_dir/git"
  local bundle="$git_dir/repository.bundle"

  mkdir -p "$git_dir" "$(dirname "$mirror_dir")"

  if [[ -d "$mirror_dir" ]]; then
    log "$full_name: updating persistent mirror"
    git_auth -C "$mirror_dir" remote set-url origin "$clone_url"
    git_auth -C "$mirror_dir" remote update --prune
  else
    log "$full_name: creating persistent mirror"
    rm -rf "$mirror_dir"
    git_auth clone --mirror "$clone_url" "$mirror_dir"
  fi

  # GitHub advertises pull refs for many repositories. Fetching explicitly is
  # harmless when none exist and preserves PR heads/merge commits when exposed.
  git_auth -C "$mirror_dir" fetch origin \
    '+refs/pull/*/head:refs/pull/*/head' \
    '+refs/pull/*/merge:refs/pull/*/merge' 2>/dev/null || true

  git -C "$mirror_dir" show-ref > "$git_dir/refs.txt" 2>/dev/null || :
  git -C "$mirror_dir" config --list --show-origin > "$git_dir/config.txt" 2>/dev/null || :
  git -C "$mirror_dir" fsck --full > "$git_dir/fsck.txt" 2>&1 || return 1

  if git -C "$mirror_dir" show-ref --quiet; then
    git -C "$mirror_dir" bundle create "$bundle" --all
    git -C "$mirror_dir" bundle verify "$bundle" > "$git_dir/bundle-verify.txt" 2>&1
    zstd -T0 -19 --rm "$bundle"
  else
    printf '{"empty_repository":true}\n' > "$git_dir/empty-repository.json"
    tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
      -C "$(dirname "$mirror_dir")" -cf - "$(basename "$mirror_dir")" \
      | zstd -T0 -19 -o "$git_dir/empty-mirror.tar.zst"
  fi

  if command -v git-lfs >/dev/null 2>&1 || git lfs version >/dev/null 2>&1; then
    if git_auth -C "$mirror_dir" lfs fetch --all origin > "$git_dir/lfs-fetch.log" 2>&1; then
      if [[ -d "$mirror_dir/lfs/objects" ]] && find "$mirror_dir/lfs/objects" -type f -print -quit | grep -q .; then
        tar --sort=name --mtime='UTC 1970-01-01' --owner=0 --group=0 --numeric-owner \
          -C "$mirror_dir" -cf - lfs/objects \
          | zstd -T0 -19 -o "$git_dir/lfs-objects.tar.zst"
      fi
    else
      warn "$full_name: Git LFS fetch failed; see lfs-fetch.log"
    fi
  fi
}

create_wiki_snapshot() {
  local full_name="$1"
  local clone_url="$2"
  local snapshot_dir="$3"
  local wiki_clone_url="${clone_url%.git}.wiki.git"
  local wiki_mirror="${BACKUP_ROOT}/mirrors/${full_name}.wiki.git"
  local wiki_dir="$snapshot_dir/wiki"
  local bundle="$wiki_dir/wiki.bundle"

  mkdir -p "$wiki_dir" "$(dirname "$wiki_mirror")"
  if [[ -d "$wiki_mirror" ]]; then
    git_auth -C "$wiki_mirror" remote update --prune >/dev/null 2>&1 || return 0
  else
    git_auth clone --mirror "$wiki_clone_url" "$wiki_mirror" >/dev/null 2>&1 || {
      rm -rf "$wiki_mirror" "$wiki_dir"
      return 0
    }
  fi

  if git -C "$wiki_mirror" show-ref --quiet; then
    git -C "$wiki_mirror" bundle create "$bundle" --all
    zstd -T0 -19 --rm "$bundle"
  fi
}

write_snapshot_manifest() {
  local full_name="$1"
  local snapshot_dir="$2"
  local default_branch="$3"
  local visibility="$4"
  local archived="$5"

  jq -n \
    --arg format_version "1" \
    --arg repository "$full_name" \
    --arg timestamp "$TIMESTAMP" \
    --arg host "$HOST_ID" \
    --arg default_branch "$default_branch" \
    --arg visibility "$visibility" \
    --argjson archived "$archived" \
    '{format_version:$format_version,repository:$repository,timestamp:$timestamp,host:$host,default_branch:$default_branch,visibility:$visibility,archived:$archived,contents:{git:"git/",metadata:"metadata/",binaries:"binaries/",wiki:"wiki/"}}' \
    > "$snapshot_dir/manifest.json"

  (
    cd "$snapshot_dir"
    find . -type f ! -name SHA256SUMS -print0 \
      | sort -z \
      | xargs -0 -r sha256sum > SHA256SUMS
  )
}

backup_repo() {
  local full_name="$1"
  local clone_url="$2"
  local default_branch="$3"
  local visibility="$4"
  local archived="$5"
  local has_wiki="$6"
  local owner="${full_name%%/*}"
  local name="${full_name#*/}"
  local repo_root="${BACKUP_ROOT}/repos/${owner}/${name}"
  local snapshot_dir="${repo_root}/snapshots/${TIMESTAMP}"
  local mirror_dir="${BACKUP_ROOT}/mirrors/${owner}/${name}.git"

  log "$full_name: starting snapshot"
  mkdir -p "$snapshot_dir"

  if ! create_git_snapshot "$full_name" "$clone_url" "$snapshot_dir" "$mirror_dir"; then
    record_failure "$full_name" git "mirror, fsck, or bundle creation failed"
    return 1
  fi

  if bool_is_true "$has_wiki"; then
    create_wiki_snapshot "$full_name" "$clone_url" "$snapshot_dir" || true
  fi

  if ! export_repository_metadata "$full_name" "$snapshot_dir"; then
    record_failure "$full_name" metadata "metadata export failed"
    return 1
  fi

  write_snapshot_manifest "$full_name" "$snapshot_dir" "$default_branch" "$visibility" "$archived"
  ln -sfn "$TIMESTAMP" "${repo_root}/latest"
  SUCCESS_COUNT=$((SUCCESS_COUNT + 1))
  log "$full_name: snapshot complete"
  return 0
}

refresh_status_repository_git_snapshot() {
  local full_name="$STATUS_REPOSITORY"
  local owner="${full_name%%/*}"
  local name="${full_name#*/}"
  local snapshot_dir="${BACKUP_ROOT}/repos/${owner}/${name}/snapshots/${TIMESTAMP}"
  local mirror_dir="${BACKUP_ROOT}/mirrors/${owner}/${name}.git"
  local clone_url

  [[ -d "$snapshot_dir" ]] || return 0
  clone_url="$(jq -r --arg name "$full_name" '.[] | select(.full_name==$name) | .clone_url' "$REPOSITORIES_JSON")"
  [[ -n "$clone_url" && "$clone_url" != "null" ]] || return 0

  log "$full_name: refreshing Git snapshot after status commit"
  rm -rf "$snapshot_dir/git"
  if create_git_snapshot "$full_name" "$clone_url" "$snapshot_dir" "$mirror_dir"; then
    (
      cd "$snapshot_dir"
      find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
    )
  else
    warn "$full_name: status commit exists online but final local refresh failed"
  fi
}
