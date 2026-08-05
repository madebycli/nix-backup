build_status_json() {
  local result="$1"
  local free_gib failures_json
  free_gib="$(df -Pk "$BACKUP_ROOT" | awk 'NR==2 {printf "%.2f", $4/1024/1024}')"
  failures_json="$(jq -s '.' "$FAILURES_JSONL")"
  jq -n \
    --arg schema_version "1" \
    --arg result "$result" \
    --arg timestamp "$TIMESTAMP" \
    --arg host "$HOST_ID" \
    --arg owner "$BACKUP_OWNER" \
    --arg scope "$BACKUP_SCOPE" \
    --arg backup_root "$BACKUP_ROOT" \
    --arg free_gib "$free_gib" \
    --argjson total "$TOTAL_COUNT" \
    --argjson succeeded "$SUCCESS_COUNT" \
    --argjson failed "$FAILURE_COUNT" \
    --argjson failures "$failures_json" \
    '{schema_version:$schema_version,result:$result,timestamp:$timestamp,host:$host,owner:$owner,scope:$scope,backup_root:$backup_root,free_gib:($free_gib|tonumber),repositories:{total:$total,succeeded:$succeeded,failed:$failed},failures:$failures}' \
    > "$STATUS_LOCAL"
}

put_status_file() {
  local path="$1"
  local message="$2"
  local sha=""
  local content
  content="$(base64 -w0 < "$STATUS_LOCAL")"
  sha="$(gh api "/repos/${STATUS_REPOSITORY}/contents/${path}?ref=${STATUS_BRANCH}" --jq .sha 2>/dev/null || true)"

  if [[ -n "$sha" ]]; then
    gh api --method PUT "/repos/${STATUS_REPOSITORY}/contents/${path}" \
      -f message="$message" \
      -f content="$content" \
      -f branch="$STATUS_BRANCH" \
      -f sha="$sha" >/dev/null
  else
    gh api --method PUT "/repos/${STATUS_REPOSITORY}/contents/${path}" \
      -f message="$message" \
      -f content="$content" \
      -f branch="$STATUS_BRANCH" >/dev/null
  fi
}

upload_status() {
  local result="$1"
  [[ -n "$STATUS_REPOSITORY" ]] || return 0
  put_status_file "status/history/${HOST_ID}/${TIMESTAMP}.json" \
    "backup(${HOST_ID}): ${result} ${TIMESTAMP}"
  put_status_file "status/latest/${HOST_ID}.json" \
    "backup(${HOST_ID}): update latest status"
  STATUS_UPLOAD_OK=true
}

main() {
  local full_name clone_url default_branch visibility archived has_wiki overall_result

  log "Starting GitHub backup run $TIMESTAMP on $HOST_ID"
  log "Owner=$BACKUP_OWNER scope=$BACKUP_SCOPE root=$BACKUP_ROOT"

  if ! wait_for_github; then
    record_failure "_global" network "GitHub remained unreachable or token authentication failed"
    TOTAL_COUNT=0
    build_status_json failure
    exit 92
  fi

  if ! check_free_space; then
    record_failure "_global" storage "free-space threshold not met"
    TOTAL_COUNT=0
    build_status_json failure
    upload_status failure || true
    exit 93
  fi

  if ! list_repositories; then
    record_failure "_global" discovery "repository discovery failed"
    build_status_json failure
    upload_status failure || true
    exit 94
  fi

  TOTAL_COUNT="$(jq 'length' "$REPOSITORIES_JSON")"
  log "Discovered $TOTAL_COUNT repositories"

  while IFS=$'\t' read -r full_name clone_url default_branch visibility archived has_wiki; do
    [[ -n "$full_name" ]] || continue
    if ! check_free_space; then
      record_failure "$full_name" storage "free-space threshold reached before repository backup"
      continue
    fi
    backup_repo "$full_name" "$clone_url" "$default_branch" "$visibility" "$archived" "$has_wiki" || true
  done < <(jq -r '.[] | [.full_name,.clone_url,(.default_branch // ""),(.visibility // (if .private then "private" else "public" end)),.archived,.has_wiki] | @tsv' "$REPOSITORIES_JSON")

  if (( FAILURE_COUNT == 0 && SUCCESS_COUNT == TOTAL_COUNT )); then
    overall_result=success
  elif (( SUCCESS_COUNT > 0 )); then
    overall_result=partial
  else
    overall_result=failure
  fi

  build_status_json "$overall_result"
  if upload_status "$overall_result"; then
    log "Status written to $STATUS_REPOSITORY"
    refresh_status_repository_git_snapshot
  else
    warn "Could not write status to $STATUS_REPOSITORY"
  fi

  jq -n \
    --arg timestamp "$TIMESTAMP" \
    --arg result "$overall_result" \
    --argjson total "$TOTAL_COUNT" \
    --argjson succeeded "$SUCCESS_COUNT" \
    --argjson failed "$FAILURE_COUNT" \
    --argjson status_uploaded "$STATUS_UPLOAD_OK" \
    '{timestamp:$timestamp,result:$result,total:$total,succeeded:$succeeded,failed:$failed,status_uploaded:$status_uploaded}' \
    > "$RUN_ROOT/manifest.json"

  (
    cd "$RUN_ROOT"
    find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 -r sha256sum > SHA256SUMS
  )

  log "Backup finished: result=$overall_result success=$SUCCESS_COUNT failed=$FAILURE_COUNT"
  [[ "$overall_result" == success ]]
}
