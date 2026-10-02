#!/usr/bin/env bash
# =============================================================================
# github_api.sh — GitHub API helper functions
# =============================================================================
# Pure helper library sourced by orchestrator.sh.  Every function uses the
# `gh api` CLI so authentication piggy-backs on GH_TOKEN in the environment.
# All JSON parsing is done with jq.
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# post_comment — Post a markdown comment on the triggering issue.
#
# Args:
#   $1  — The issue number.
#   $2  — The markdown body text.
# ---------------------------------------------------------------------------
post_comment() {
  local issue_number="$1"
  local body="$2"

  gh api \
    --method POST \
    "/repos/${HUB_REPO}/issues/${issue_number}/comments" \
    -f body="$body" \
    --silent
}

# ---------------------------------------------------------------------------
# reply_to_comment — React to a specific comment and post a threaded reply.
#
# GitHub Issues don't support true threads, so we quote the original comment
# and post a new one referencing it.
#
# Args:
#   $1  — Issue number.
#   $2  — The comment ID being replied to.
#   $3  — The reply body text.
# ---------------------------------------------------------------------------
reply_to_comment() {
  local issue_number="$1"
  local comment_id="$2"
  local body="$3"

  # Add a 👀 reaction to acknowledge we saw the comment
  gh api \
    --method POST \
    "/repos/${HUB_REPO}/issues/comments/${comment_id}/reactions" \
    -f content=eyes \
    --silent 2>/dev/null || true

  # Post the reply referencing the original comment
  local full_body
  full_body="$(printf '> Re: [comment](%s)\n\n%s' \
    "https://github.com/${HUB_REPO}/issues/${issue_number}#issuecomment-${comment_id}" \
    "$body")"

  post_comment "$issue_number" "$full_body"
}

# ---------------------------------------------------------------------------
# get_issue_body — Fetch the issue body (the opening post).
#
# Args:
#   $1  — Issue number.
#
# Stdout: The raw body text.
# ---------------------------------------------------------------------------
get_issue_body() {
  local issue_number="$1"

  gh issue view "$issue_number" \
    --repo "$HUB_REPO" \
    --json body \
    --jq '.body'
}

# ---------------------------------------------------------------------------
# get_new_comments — Return comments created strictly after a given ISO-8601
#                    timestamp.  Each line of output is a JSON object with
#                    { id, body, created_at }.
#
# Args:
#   $1  — Issue number.
#   $2  — ISO-8601 "since" timestamp (exclusive lower bound).
#
# Stdout: One JSON object per line (NDJSON).
# ---------------------------------------------------------------------------
get_new_comments() {
  local issue_number="$1"
  local since="$2"

  # gh api supports pagination; --paginate ensures we never miss comments
  # even if the thread grows beyond 30 (the default page size).
  gh api \
    --method GET \
    "/repos/${HUB_REPO}/issues/${issue_number}/comments" \
    -f since="$since" \
    -f per_page=100 \
    --paginate \
    --jq '.[] | select(.created_at > "'"$since"'") | {id: .id, body: .body, created_at: .created_at}'
}

# ---------------------------------------------------------------------------
# create_repo — Create a new public repository under the authenticated user's
#               account and return the HTTPS clone URL.
#
# Args:
#   $1  — Repository name (e.g. "my-cool-app").
#
# Stdout: The clone URL (https://github.com/owner/repo.git).
# ---------------------------------------------------------------------------
create_repo() {
  local repo_name="$1"

  gh repo create "$repo_name" \
    --public \
    --confirm 2>/dev/null \
  || gh repo create "${REPO_OWNER}/${repo_name}" \
    --public \
    --clone=false

  echo "https://github.com/${REPO_OWNER}/${repo_name}.git"
}

# ---------------------------------------------------------------------------
# extract_project_name — Derive a kebab-case project name from the issue body.
#
# Heuristic: take the first non-empty line, lowercase it, replace spaces and
# special chars with hyphens, truncate to 50 chars.
#
# Args:
#   $1  — The raw issue body.
#
# Stdout: The sanitised project name.
# ---------------------------------------------------------------------------
extract_project_name() {
  local body="$1"

  echo "$body" \
    | head -n 5 \
    | grep -m1 -oP '(?i)(?:project\s*(?:name)?[:=]\s*|#\s*).+' \
    | sed 's/^[#:= ]*//' \
    | tr '[:upper:]' '[:lower:]' \
    | sed 's/[^a-z0-9]/-/g' \
    | sed 's/--*/-/g; s/^-//; s/-$//' \
    | cut -c1-50 \
  || {
    # Fallback: use first line verbatim
    echo "$body" \
      | head -n1 \
      | tr '[:upper:]' '[:lower:]' \
      | sed 's/[^a-z0-9]/-/g' \
      | sed 's/--*/-/g; s/^-//; s/-$//' \
      | cut -c1-50
  }
}
