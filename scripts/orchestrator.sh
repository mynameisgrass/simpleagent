#!/usr/bin/env bash
# =============================================================================
# orchestrator.sh — IssueOps Agent Hub: Main Execution Loop
# =============================================================================
#
# Lifecycle:
#   Phase 1 — Boot: read issue body, extract project idea, post milestone.
#   Phase 2 — Scaffold: create directory, init git, create remote repo.
#   Phase 3 — Initial generation: run Aider on the issue body, commit, push,
#             deploy to Vercel.
#   Phase 4 — Continuous loop: poll issue comments every 15 s, feed new ones
#             to Aider, commit+push+deploy, reply on the issue thread.
#   Phase 5 — Kill switch: if a comment contains "!stop", post goodbye and
#             exit 0.
#
# Environment (set by the workflow):
#   GH_TOKEN, VERCEL_TOKEN, GEMINI_API_KEY, GROQ_API_KEY,
#   ISSUE_NUMBER, REPO_OWNER, HUB_REPO
# =============================================================================

set -Eeuo pipefail

# ---------------------------------------------------------------------------
# Resolve the absolute path of the hub repository root (where the workflow
# checked out the code).  This lets us source helper scripts reliably.
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
HUB_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# Source helper functions
# shellcheck source=scripts/github_api.sh
source "${SCRIPT_DIR}/github_api.sh"

# ---------------------------------------------------------------------------
# Global configuration
# ---------------------------------------------------------------------------
POLL_INTERVAL=15          # seconds between comment polls
WORK_DIR=""               # Set during Phase 2
PROJECT_NAME=""           # Set during Phase 1
LAST_PROCESSED_TS=""      # ISO-8601 watermark for comment polling

# ---------------------------------------------------------------------------
# LLM model chain — tried in order. Each entry: "ENV_VAR:model_string"
#   1. Gemini 3 Flash (primary, via GEMINI_API_KEY) — retried 3 times
#   2. Groq Llama 3.3 70B (via GROQ_API_KEY)
#   3. Gemini 2.0 Flash (safe stable model via GEMINI_API_KEY)
# ---------------------------------------------------------------------------
MODEL_PRIMARY="gemini/gemini-3-flash-preview"
MODEL_GROQ="groq/llama-3.3-70b-versatile"
MODEL_FALLBACK="gemini/gemini-2.0-flash"
PRIMARY_RETRIES=3

# ---------------------------------------------------------------------------
# log — Timestamped logging to stderr.
# ---------------------------------------------------------------------------
log() {
  echo "[$(date -u +"%Y-%m-%dT%H:%M:%SZ")] $*" >&2
}

# ---------------------------------------------------------------------------
# _aider_has_errors — Check the output log for known API error signatures.
#                     Aider often exits 0 even on 404/503/rate-limit errors.
#
# Args:
#   $1  — Path to the Aider output log.
#
# Returns: 0 if errors found, 1 if clean.
# ---------------------------------------------------------------------------
_aider_has_errors() {
  grep -qiE '(NotFoundError|RateLimitError|APIError|APIConnectionError|AuthenticationError|InternalServerError|ServiceUnavailableError|models/.*is not found|VertexAIError|Vertex_ai_betaException)' "$1" 2>/dev/null
}

# ---------------------------------------------------------------------------
# _try_aider — Run Aider once with a specific model.  Returns 0 on success.
#
# Args:
#   $1 — Model string (e.g. "gemini/gemini-3-flash-preview").
#   $2 — The natural-language message.
# ---------------------------------------------------------------------------
_try_aider() {
  local model="$1"
  local message="$2"
  local exit_code=0

  log "  → Trying model: ${model}"

  aider \
    --model "$model" \
    --no-auto-commits \
    --yes-always \
    --no-suggest-shell-commands \
    --no-show-model-warnings \
    --message "$message" 2>&1 | tee /tmp/aider_output.log \
  || exit_code=$?

  # Catch silent API failures (Aider exits 0 on 404/503)
  if [[ $exit_code -eq 0 ]] && _aider_has_errors /tmp/aider_output.log; then
    log "  ✗ Model exited 0 but output contains API errors."
    return 1
  fi

  return "$exit_code"
}

# ---------------------------------------------------------------------------
# run_aider — Execute Aider with the hybrid retry chain:
#   1. Primary (gemini-3-flash) — up to 3 retries with backoff
#   2. Groq (llama-3.3-70b)    — 1 attempt
#   3. Fallback (gemini-2.0-flash) — 1 attempt
#
# Args:
#   $1 — The natural-language instruction for Aider.
#
# Returns: 0 on success, 1 if entire chain fails.
# ---------------------------------------------------------------------------
run_aider() {
  local message="$1"

  # ----- Stage 1: Primary model with retries -----
  log "Running Aider — Stage 1: ${MODEL_PRIMARY} (up to ${PRIMARY_RETRIES} attempts)..."
  local attempt=1
  while [[ $attempt -le $PRIMARY_RETRIES ]]; do
    log "  Attempt ${attempt}/${PRIMARY_RETRIES}..."

    if _try_aider "$MODEL_PRIMARY" "$message"; then
      log "✅ Aider completed successfully (${MODEL_PRIMARY}, attempt ${attempt})."
      return 0
    fi

    log "  ✗ Attempt ${attempt} failed."
    attempt=$((attempt + 1))

    # Backoff: 5s, 10s before retries (skip sleep on last failure)
    if [[ $attempt -le $PRIMARY_RETRIES ]]; then
      local wait_secs=$(( (attempt - 1) * 5 ))
      log "  Waiting ${wait_secs}s before retry..."
      sleep "$wait_secs"
    fi
  done

  # ----- Stage 2: Groq -----
  log "Running Aider — Stage 2: ${MODEL_GROQ}..."
  post_comment "$ISSUE_NUMBER" \
    "⚠️ Primary model (\`${MODEL_PRIMARY}\`) failed after ${PRIMARY_RETRIES} attempts. Trying Groq..."

  if _try_aider "$MODEL_GROQ" "$message"; then
    log "✅ Aider completed successfully (${MODEL_GROQ})."
    return 0
  fi

  # ----- Stage 3: Stable Gemini fallback -----
  log "Running Aider — Stage 3: ${MODEL_FALLBACK}..."
  post_comment "$ISSUE_NUMBER" \
    "⚠️ Groq also failed. Last resort: \`${MODEL_FALLBACK}\`..."

  if _try_aider "$MODEL_FALLBACK" "$message"; then
    log "✅ Aider completed successfully (${MODEL_FALLBACK})."
    return 0
  fi

  # ----- All failed -----
  log "❌ All models in the chain failed."
  post_comment "$ISSUE_NUMBER" \
    "❌ All models failed (\`${MODEL_PRIMARY}\` ×${PRIMARY_RETRIES}, \`${MODEL_GROQ}\`, \`${MODEL_FALLBACK}\`). Will retry on the next comment."
  return 1
}

# ---------------------------------------------------------------------------
# commit_and_push — Stage everything, commit with a descriptive message,
#                   and push to the remote.
#
# Args:
#   $1 — Commit message.
# ---------------------------------------------------------------------------
commit_and_push() {
  local commit_msg="$1"

  cd "$WORK_DIR"

  # Only commit if there are actual changes
  if git diff --quiet && git diff --cached --quiet; then
    log "No changes to commit."
    return 0
  fi

  git add -A
  git commit -m "$commit_msg" --no-verify
  git push origin main
  log "Pushed commit: ${commit_msg}"
}

# ---------------------------------------------------------------------------
# deploy_vercel — Deploy the current working directory to Vercel production.
#
# Returns the deployment URL via stdout.
# ---------------------------------------------------------------------------
deploy_vercel() {
  cd "$WORK_DIR"

  log "Deploying to Vercel..."

  local deploy_url
  deploy_url=$(
    vercel deploy --prod --yes --token "$VERCEL_TOKEN" 2>&1 \
    | grep -oP 'https://[^\s]+\.vercel\.app' \
    | tail -1
  ) || true

  if [[ -z "$deploy_url" ]]; then
    # If we couldn't parse the URL, try a simpler deploy and capture
    deploy_url=$(
      vercel --prod --yes --token "$VERCEL_TOKEN" 2>&1 \
      | tail -1
    ) || true
  fi

  echo "$deploy_url"
  log "Vercel deployment: ${deploy_url:-'(URL not captured)'}"
}

# =============================================================================
# PHASE 1: BOOT — Read the issue body and extract the project idea
# =============================================================================
log "═══════════════════════════════════════════════════════"
log " PHASE 1: Booting agent for issue #${ISSUE_NUMBER}"
log "═══════════════════════════════════════════════════════"

ISSUE_BODY="$(get_issue_body "$ISSUE_NUMBER")" || true
ISSUE_TITLE="$(get_issue_title "$ISSUE_NUMBER")" || true

# If body is empty, use the title as the spec (user might only type a header)
if [[ -z "$ISSUE_BODY" ]]; then
  log "Issue body is empty — using title as specification."
  ISSUE_BODY="$ISSUE_TITLE"
fi

if [[ -z "$ISSUE_BODY" ]]; then
  post_comment "$ISSUE_NUMBER" "❌ Issue has no title or body. Nothing to build. Exiting."
  exit 1
fi

# Prefer title for project name (it's usually shorter/cleaner), fall back to body
PROJECT_NAME="$(extract_project_name "${ISSUE_TITLE:-$ISSUE_BODY}")"

# Guard against empty project name
if [[ -z "$PROJECT_NAME" ]]; then
  PROJECT_NAME="agent-project-$(date +%s)"
fi

log "Project name resolved to: ${PROJECT_NAME}"

# Post the first milestone comment
post_comment "$ISSUE_NUMBER" \
  "🚀 Agent booted. Generating project **\`${PROJECT_NAME}\`**...

**LLM Chain:**
1. 🧠 \`${MODEL_PRIMARY}\` (×${PRIMARY_RETRIES} retries)
2. 🔄 \`${MODEL_GROQ}\` (Groq)
3. 🛡️ \`${MODEL_FALLBACK}\` (stable fallback)

⏱️ Session: 3 hours | 🔁 Poll: ${POLL_INTERVAL}s

I'll read your issue, generate the initial code, push it to a new repo, and deploy to Vercel. Then I'll watch for your follow-up comments."

# =============================================================================
# PHASE 2: SCAFFOLD — Create the project directory and remote repository
# =============================================================================
log "═══════════════════════════════════════════════════════"
log " PHASE 2: Scaffolding project"
log "═══════════════════════════════════════════════════════"

WORK_DIR="${GITHUB_WORKSPACE:-/tmp}/${PROJECT_NAME}"
mkdir -p "$WORK_DIR"
cd "$WORK_DIR"

# Initialise a fresh git repository
git init
git checkout -b main

# Configure git identity (uses the GitHub Actions bot)
git config user.name "IssueOps Agent"
git config user.email "issueops-agent@users.noreply.github.com"

# Create the remote repository on GitHub
log "Creating remote repository: ${REPO_OWNER}/${PROJECT_NAME}"
CLONE_URL="$(create_repo "$PROJECT_NAME")"

# Use token-authenticated URL so git push works without interactive prompts
AUTH_CLONE_URL="https://x-access-token:${GH_TOKEN}@github.com/${REPO_OWNER}/${PROJECT_NAME}.git"
git remote add origin "$AUTH_CLONE_URL"

log "Remote repository ready at ${CLONE_URL}"

# =============================================================================
# PHASE 3: INITIAL CODE GENERATION
# =============================================================================
log "═══════════════════════════════════════════════════════"
log " PHASE 3: Initial code generation via Aider"
log "═══════════════════════════════════════════════════════"

# Create a minimal README so that the first Aider run has a file to work with
cat > README.md <<EOF
# ${PROJECT_NAME}

> Auto-generated by the IssueOps Agent Hub.

## Idea

${ISSUE_BODY}
EOF

# Run Aider with the full issue body as the initial instruction
run_aider "You are building a new project called '${PROJECT_NAME}'. Here is the full specification from the developer:

${ISSUE_BODY}

Please generate the complete initial codebase following the specification above. Create all necessary files with production-ready code."

# Commit and push the initial generation
commit_and_push "feat: initial project generation from issue #${ISSUE_NUMBER}"

# Deploy to Vercel
DEPLOY_URL="$(deploy_vercel)"

# Post milestone 2
post_comment "$ISSUE_NUMBER" \
  "✅ Initial code generated and deployed!

📦 **Repository:** [${REPO_OWNER}/${PROJECT_NAME}](https://github.com/${REPO_OWNER}/${PROJECT_NAME})
🌐 **Live preview:** ${DEPLOY_URL:-'_(deploying...)_'}

I'm now watching this issue for follow-up instructions. Post a comment and I'll update the code.

> 💡 Tip: Send \`!stop\` to end the session early."

# =============================================================================
# PHASE 4: CONTINUOUS POLLING LOOP
# =============================================================================
log "═══════════════════════════════════════════════════════"
log " PHASE 4: Entering continuous polling loop"
log "═══════════════════════════════════════════════════════"

# Set the watermark to "now" so we only pick up comments posted after boot
LAST_PROCESSED_TS="$(date -u +"%Y-%m-%dT%H:%M:%SZ")"

while true; do
  sleep "$POLL_INTERVAL"

  # -------------------------------------------------------------------
  # Fetch comments newer than our watermark
  # -------------------------------------------------------------------
  NEW_COMMENTS="$(get_new_comments "$ISSUE_NUMBER" "$LAST_PROCESSED_TS")"

  if [[ -z "$NEW_COMMENTS" ]]; then
    continue
  fi

  # -------------------------------------------------------------------
  # Process each new comment (one JSON object per line)
  # -------------------------------------------------------------------
  while IFS= read -r comment_json; do
    COMMENT_ID="$(echo "$comment_json"  | jq -r '.id')"
    COMMENT_BODY="$(echo "$comment_json" | jq -r '.body')"
    COMMENT_TS="$(echo "$comment_json"   | jq -r '.created_at')"

    log "Processing comment #${COMMENT_ID} (${COMMENT_TS})"

    # Advance the watermark immediately to avoid re-processing
    LAST_PROCESSED_TS="$COMMENT_TS"

    # Skip comments posted by the bot itself (they contain our markers)
    if echo "$COMMENT_BODY" | grep -qE '(🚀 Agent booted|✅ Code updated|✅ Initial code|✅ \*\*Environment|🛑 Terminating|⚠️ Primary model|⚠️ Groq also|⚠️ Code generation|🔄 Processing your|❌ (All models|Both primary|Agent setup)|⏳ \*\*Agent starting|> Re: \[comment\])'; then
      log "Skipping bot-authored comment #${COMMENT_ID}"
      continue
    fi

    # =================================================================
    # PHASE 5: KILL SWITCH
    # =================================================================
    if echo "$COMMENT_BODY" | grep -qF '!stop'; then
      log "🛑 Kill switch activated by comment #${COMMENT_ID}"
      post_comment "$ISSUE_NUMBER" \
        "🛑 Terminating 3-hour session. Goodbye!

**Session summary:**
- 📦 Repository: [${REPO_OWNER}/${PROJECT_NAME}](https://github.com/${REPO_OWNER}/${PROJECT_NAME})
- 🌐 Last deployment: ${DEPLOY_URL:-'N/A'}
- ⏱️ Session ended at: $(date -u +"%Y-%m-%dT%H:%M:%SZ")"
      exit 0
    fi

    # =================================================================
    # Process the instruction: Aider → commit → push → deploy → reply
    # =================================================================
    log "Feeding comment to Aider..."

    # Acknowledge the comment
    reply_to_comment "$ISSUE_NUMBER" "$COMMENT_ID" \
      "🔄 Processing your request..."

    cd "$WORK_DIR"

    if run_aider "$COMMENT_BODY"; then
      commit_and_push "feat: update from issue comment #${COMMENT_ID}"

      DEPLOY_URL="$(deploy_vercel)"

      reply_to_comment "$ISSUE_NUMBER" "$COMMENT_ID" \
        "✅ Code updated and pushing to Vercel.

🌐 **Preview:** ${DEPLOY_URL:-'_(deploying...)_'}"
    else
      reply_to_comment "$ISSUE_NUMBER" "$COMMENT_ID" \
        "⚠️ Code generation failed for this instruction. The session remains active — try rephrasing or send \`!stop\` to end."
    fi

  done <<< "$NEW_COMMENTS"
done
