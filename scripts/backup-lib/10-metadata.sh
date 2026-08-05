export_branch_protections() {
  local full_name="$1"
  local metadata_dir="$2"
  local branch branch_encoded
  mkdir -p "$metadata_dir/branch-protection"

  jq -r '.[] | select(.protected == true) | .name' "$metadata_dir/branches.json" 2>/dev/null \
    | while IFS= read -r branch; do
        [[ -n "$branch" ]] || continue
        branch_encoded="$(jq -rn --arg value "$branch" '$value|@uri')"
        api_optional_object \
          "/repos/${full_name}/branches/${branch_encoded}/protection" \
          "$metadata_dir/branch-protection/$(safe_asset_name "$branch").json" \
          "$full_name branch protection $branch"
      done
}

export_pull_requests() {
  local full_name="$1"
  local metadata_dir="$2"
  local number pr_dir

  mkdir -p "$metadata_dir/pulls"
  api_optional_array "/repos/${full_name}/pulls?state=all&sort=created&direction=asc&per_page=100" \
    "$metadata_dir/pulls.json" "$full_name pull requests"
  api_optional_array "/repos/${full_name}/pulls/comments?sort=created&direction=asc&per_page=100" \
    "$metadata_dir/pull-review-comments-all.json" "$full_name global pull review comments"

  jq -r '.[].number' "$metadata_dir/pulls.json" 2>/dev/null | while IFS= read -r number; do
    [[ -n "$number" ]] || continue
    pr_dir="$metadata_dir/pulls/$number"
    mkdir -p "$pr_dir"
    api_optional_object "/repos/${full_name}/pulls/${number}" "$pr_dir/pull.json" "$full_name PR $number"
    api_optional_array "/repos/${full_name}/issues/${number}/comments?per_page=100" "$pr_dir/conversation-comments.json" "$full_name PR $number comments"
    api_optional_array "/repos/${full_name}/pulls/${number}/reviews?per_page=100" "$pr_dir/reviews.json" "$full_name PR $number reviews"
    api_optional_array "/repos/${full_name}/pulls/${number}/comments?per_page=100" "$pr_dir/review-comments.json" "$full_name PR $number review comments"
    api_optional_array "/repos/${full_name}/pulls/${number}/commits?per_page=100" "$pr_dir/commits.json" "$full_name PR $number commits"
    api_optional_array "/repos/${full_name}/pulls/${number}/files?per_page=100" "$pr_dir/files.json" "$full_name PR $number files"
    gh api -H 'Accept: application/vnd.github.v3.diff' "/repos/${full_name}/pulls/${number}" > "$pr_dir/pr.diff" 2>/dev/null || true
    gh api -H 'Accept: application/vnd.github.v3.patch' "/repos/${full_name}/pulls/${number}" > "$pr_dir/pr.patch" 2>/dev/null || true
  done
}

export_issues() {
  local full_name="$1"
  local metadata_dir="$2"
  api_optional_array "/repos/${full_name}/issues?state=all&sort=created&direction=asc&per_page=100" \
    "$metadata_dir/issues.json" "$full_name issues"
  api_optional_array "/repos/${full_name}/issues/comments?sort=created&direction=asc&per_page=100" \
    "$metadata_dir/issue-comments.json" "$full_name issue comments"
  api_optional_array "/repos/${full_name}/issues/events?per_page=100" \
    "$metadata_dir/issue-events.json" "$full_name issue events"
  api_optional_array "/repos/${full_name}/labels?per_page=100" \
    "$metadata_dir/labels.json" "$full_name labels"
  api_optional_array "/repos/${full_name}/milestones?state=all&sort=due_on&direction=asc&per_page=100" \
    "$metadata_dir/milestones.json" "$full_name milestones"
}

export_actions() {
  local full_name="$1"
  local metadata_dir="$2"
  local binary_dir="$3"
  local run_id artifact_id artifact_name expired

  mkdir -p "$metadata_dir/actions/runs" "$binary_dir/actions/logs" "$binary_dir/actions/artifacts"
  api_optional_field_array "/repos/${full_name}/actions/workflows?per_page=100" workflows \
    "$metadata_dir/actions/workflows.json" "$full_name workflows"
  api_optional_field_array "/repos/${full_name}/actions/runs?per_page=100" workflow_runs \
    "$metadata_dir/actions/runs.json" "$full_name workflow runs"
  api_optional_field_array "/repos/${full_name}/actions/artifacts?per_page=100" artifacts \
    "$metadata_dir/actions/artifacts.json" "$full_name workflow artifacts"
  api_optional_field_array "/repos/${full_name}/actions/caches?per_page=100" actions_caches \
    "$metadata_dir/actions/caches.json" "$full_name Actions caches"
  api_optional_field_array "/repos/${full_name}/actions/variables?per_page=100" variables \
    "$metadata_dir/actions/variables.json" "$full_name Actions variables"
  api_optional_field_array "/repos/${full_name}/actions/secrets?per_page=100" secrets \
    "$metadata_dir/actions/secret-names.json" "$full_name Actions secret names"

  jq -r '.[].id' "$metadata_dir/actions/runs.json" 2>/dev/null | while IFS= read -r run_id; do
    [[ -n "$run_id" ]] || continue
    api_optional_object "/repos/${full_name}/actions/runs/${run_id}" \
      "$metadata_dir/actions/runs/${run_id}.json" "$full_name workflow run $run_id"
    api_optional_array "/repos/${full_name}/actions/runs/${run_id}/jobs?filter=all&per_page=100" \
      "$metadata_dir/actions/runs/${run_id}-jobs.json" "$full_name workflow jobs $run_id"
    if bool_is_true "$INCLUDE_ACTION_LOGS"; then
      gh api "/repos/${full_name}/actions/runs/${run_id}/logs" \
        > "$binary_dir/actions/logs/${run_id}.zip" 2>/dev/null \
        || rm -f "$binary_dir/actions/logs/${run_id}.zip"
    fi
  done

  if bool_is_true "$INCLUDE_ARTIFACTS"; then
    jq -r '.[] | [.id, .name, (.expired|tostring)] | @tsv' "$metadata_dir/actions/artifacts.json" 2>/dev/null \
      | while IFS=$'\t' read -r artifact_id artifact_name expired; do
          [[ -n "$artifact_id" ]] || continue
          [[ "$expired" == "false" ]] || continue
          artifact_name="$(safe_asset_name "$artifact_name")"
          gh api "/repos/${full_name}/actions/artifacts/${artifact_id}/zip" \
            > "$binary_dir/actions/artifacts/${artifact_id}-${artifact_name}.zip" 2>/dev/null \
            || rm -f "$binary_dir/actions/artifacts/${artifact_id}-${artifact_name}.zip"
        done
  fi
}

export_releases() {
  local full_name="$1"
  local metadata_dir="$2"
  local binary_dir="$3"
  local asset_id asset_name

  mkdir -p "$binary_dir/releases"
  api_optional_array "/repos/${full_name}/releases?per_page=100" \
    "$metadata_dir/releases.json" "$full_name releases"

  if bool_is_true "$INCLUDE_RELEASE_ASSETS"; then
    jq -r '.[] | .assets[]? | [.id, .name] | @tsv' "$metadata_dir/releases.json" 2>/dev/null \
      | while IFS=$'\t' read -r asset_id asset_name; do
          [[ -n "$asset_id" ]] || continue
          asset_name="$(safe_asset_name "$asset_name")"
          gh api -H 'Accept: application/octet-stream' "/repos/${full_name}/releases/assets/${asset_id}" \
            > "$binary_dir/releases/${asset_id}-${asset_name}" 2>/dev/null \
            || rm -f "$binary_dir/releases/${asset_id}-${asset_name}"
        done
  fi
}

export_rulesets_and_environments() {
  local full_name="$1"
  local metadata_dir="$2"
  local id name encoded

  mkdir -p "$metadata_dir/rulesets" "$metadata_dir/environments"
  jq -r '.[].id' "$metadata_dir/rulesets.json" 2>/dev/null | while IFS= read -r id; do
    [[ -n "$id" ]] || continue
    api_optional_object "/repos/${full_name}/rulesets/${id}" \
      "$metadata_dir/rulesets/${id}.json" "$full_name ruleset $id"
  done

  jq -r '.[].name' "$metadata_dir/environments.json" 2>/dev/null | while IFS= read -r name; do
    [[ -n "$name" ]] || continue
    encoded="$(jq -rn --arg value "$name" '$value|@uri')"
    api_optional_object "/repos/${full_name}/environments/${encoded}" \
      "$metadata_dir/environments/$(safe_asset_name "$name").json" "$full_name environment $name"
    api_optional_array "/repos/${full_name}/environments/${encoded}/deployment-branch-policies?per_page=100" \
      "$metadata_dir/environments/$(safe_asset_name "$name")-branch-policies.json" \
      "$full_name environment branch policies $name"
  done
}

export_security_metadata() {
  local full_name="$1"
  local metadata_dir="$2"
  local state
  mkdir -p "$metadata_dir/security"

  api_optional_array "/repos/${full_name}/security-advisories?state=all&per_page=100" \
    "$metadata_dir/security/advisories.json" "$full_name repository security advisories"

  for state in open dismissed fixed auto_dismissed; do
    api_optional_array "/repos/${full_name}/dependabot/alerts?state=${state}&per_page=100" \
      "$metadata_dir/security/dependabot-${state}.json" "$full_name Dependabot alerts $state"
  done
  for state in open dismissed fixed; do
    api_optional_array "/repos/${full_name}/code-scanning/alerts?state=${state}&per_page=100" \
      "$metadata_dir/security/code-scanning-${state}.json" "$full_name code scanning alerts $state"
  done
  for state in open resolved; do
    api_optional_array "/repos/${full_name}/secret-scanning/alerts?state=${state}&per_page=100" \
      "$metadata_dir/security/secret-scanning-${state}.json" "$full_name secret scanning alerts $state"
  done
}

export_discussions() {
  local full_name="$1"
  local metadata_dir="$2"
  local owner="${full_name%%/*}"
  local name="${full_name#*/}"
  local temporary="$metadata_dir/discussions.json.tmp"
  local query

  query='query($owner:String!, $name:String!, $endCursor:String) {
    repository(owner:$owner, name:$name) {
      discussionCategories(first:100) {
        nodes { id name slug description emoji isAnswerable }
      }
      discussions(first:100, after:$endCursor, orderBy:{field:CREATED_AT,direction:ASC}) {
        nodes {
          id number title body url createdAt updatedAt closedAt locked
          author { login }
          category { id name slug }
          answer { id body createdAt updatedAt author { login } }
          comments(first:100) {
            nodes {
              id body createdAt updatedAt isAnswer
              author { login }
              replies(first:100) {
                nodes { id body createdAt updatedAt author { login } }
              }
            }
            pageInfo { hasNextPage endCursor }
          }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }'

  if gh api graphql --paginate -f query="$query" -F owner="$owner" -F name="$name" \
      | jq -s '{
          categories: ([.[].data.repository.discussionCategories.nodes[]?] | unique_by(.id)),
          discussions: [.[].data.repository.discussions.nodes[]?],
          note: "Nested comments and replies are exported up to 100 per discussion/comment; GitHub GraphQL does not recursively paginate them in this query."
        }' > "$temporary"; then
    mv "$temporary" "$metadata_dir/discussions.json"
  else
    rm -f "$temporary"
    printf '{"unavailable":true}\n' > "$metadata_dir/discussions.json"
    warn "$full_name discussions could not be exported"
  fi
}

export_repository_metadata() {
  local full_name="$1"
  local snapshot_dir="$2"
  local metadata_dir="$snapshot_dir/metadata"
  local binary_dir="$snapshot_dir/binaries"

  mkdir -p "$metadata_dir" "$binary_dir"
  api_optional_object "/repos/${full_name}" "$metadata_dir/repository.json" "$full_name repository metadata"
  api_optional_array "/repos/${full_name}/branches?per_page=100" "$metadata_dir/branches.json" "$full_name branches"
  api_optional_array "/repos/${full_name}/tags?per_page=100" "$metadata_dir/tags.json" "$full_name tags"
  api_optional_object "/repos/${full_name}/languages" "$metadata_dir/languages.json" "$full_name languages"
  api_optional_array "/repos/${full_name}/contributors?anon=1&per_page=100" "$metadata_dir/contributors.json" "$full_name contributors"
  api_optional_array "/repos/${full_name}/collaborators?affiliation=all&per_page=100" "$metadata_dir/collaborators.json" "$full_name collaborators"
  api_optional_array "/repos/${full_name}/teams?per_page=100" "$metadata_dir/teams.json" "$full_name teams"
  api_optional_array "/repos/${full_name}/hooks?per_page=100" "$metadata_dir/webhooks.json" "$full_name webhooks"
  api_optional_array "/repos/${full_name}/keys?per_page=100" "$metadata_dir/deploy-keys.json" "$full_name deploy keys"
  api_optional_array "/repos/${full_name}/rulesets?per_page=100" "$metadata_dir/rulesets.json" "$full_name rulesets"
  api_optional_field_array "/repos/${full_name}/environments?per_page=100" environments "$metadata_dir/environments.json" "$full_name environments"
  api_optional_array "/repos/${full_name}/deployments?per_page=100" "$metadata_dir/deployments.json" "$full_name deployments"
  api_optional_object "/repos/${full_name}/pages" "$metadata_dir/pages.json" "$full_name Pages configuration"
  api_optional_object "/repos/${full_name}/community/profile" "$metadata_dir/community-profile.json" "$full_name community profile"
  api_optional_object "/repos/${full_name}/topics" "$metadata_dir/topics.json" "$full_name topics"
  api_optional_array "/repos/${full_name}/comments?per_page=100" "$metadata_dir/commit-comments.json" "$full_name commit comments"
  api_optional_array "/repos/${full_name}/stargazers?per_page=100" "$metadata_dir/stargazers.json" "$full_name stargazers"
  api_optional_array "/repos/${full_name}/subscribers?per_page=100" "$metadata_dir/subscribers.json" "$full_name subscribers"
  api_optional_array "/repos/${full_name}/forks?sort=oldest&per_page=100" "$metadata_dir/forks.json" "$full_name forks"
  api_optional_array "/repos/${full_name}/properties/values?per_page=100" "$metadata_dir/custom-properties.json" "$full_name custom properties"
  api_optional_array "/repos/${full_name}/invitations?per_page=100" "$metadata_dir/invitations.json" "$full_name invitations"
  api_optional_field_array "/repos/${full_name}/dependabot/secrets?per_page=100" secrets "$metadata_dir/dependabot-secret-names.json" "$full_name Dependabot secret names"
  api_optional_field_array "/repos/${full_name}/codespaces/secrets?per_page=100" secrets "$metadata_dir/codespaces-secret-names.json" "$full_name Codespaces secret names"

  export_branch_protections "$full_name" "$metadata_dir"
  export_rulesets_and_environments "$full_name" "$metadata_dir"
  export_security_metadata "$full_name" "$metadata_dir"
  export_discussions "$full_name" "$metadata_dir"
  export_issues "$full_name" "$metadata_dir"
  export_pull_requests "$full_name" "$metadata_dir"
  export_actions "$full_name" "$metadata_dir" "$binary_dir"
  export_releases "$full_name" "$metadata_dir" "$binary_dir"
}
