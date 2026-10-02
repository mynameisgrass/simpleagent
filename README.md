# IssueOps Agent Hub

> A 3-hour autonomous coding environment powered by GitHub Actions, Aider, and Vercel.

Open a GitHub Issue, label it `agent-run`, and an Ubuntu runner boots up to read your spec, generate a full codebase with AI, push it to a new repo, deploy to Vercel, and then **keep listening** for follow-up instructions in the issue thread — for up to 3 hours.

---

## How It Works

```
┌─────────────┐      label: agent-run       ┌──────────────────┐
│  GitHub      │ ─────────────────────────▶  │  GitHub Actions  │
│  Issue       │                             │  Runner (3 hrs)  │
│              │  ◀── status comments ─────  │                  │
└─────────────┘                              └──────┬───────────┘
                                                    │
                        ┌───────────────────────────┼──────────────┐
                        │                           │              │
                   ┌────▼────┐              ┌───────▼──┐    ┌─────▼─────┐
                   │  Aider  │              │  GitHub   │    │  Vercel   │
                   │  (AI)   │              │  Repo     │    │  Deploy   │
                   └─────────┘              └──────────┘    └───────────┘
```

### Lifecycle

| Phase | What Happens |
|-------|-------------|
| **Boot** | Reads the issue body, extracts a project name, posts a milestone comment |
| **Scaffold** | Creates a local directory, `git init`, and `gh repo create` for a new public repo |
| **Generate** | Feeds the full issue spec to Aider → commits → pushes → deploys to Vercel |
| **Poll Loop** | Every 15 seconds, checks for new issue comments and feeds them to Aider |
| **Kill Switch** | Comment `!stop` anywhere in the thread to end the session early |

---

## Setup

### 1. Fork or clone this repository

```bash
git clone https://github.com/YOUR_USERNAME/nicetool.git
cd nicetool
```

### 2. Configure repository secrets

Go to **Settings → Secrets and variables → Actions** and add:

| Secret | Description | Required |
|--------|-------------|----------|
| `GH_PAT` | GitHub Personal Access Token with `repo`, `workflow`, and `admin:org` scopes. Must be able to create repositories. | ✅ |
| `VERCEL_TOKEN` | Vercel API token from [vercel.com/account/tokens](https://vercel.com/account/tokens) | ✅ |
| `GEMINI_API_KEY` | Google Gemini API key (primary LLM for Aider) | ✅ |
| `GROQ_API_KEY` | Groq API key (fallback LLM if Gemini hits rate limits) | ✅ |

#### Creating the GitHub PAT (Fine-grained token — recommended)

1. Go to [github.com/settings/tokens](https://github.com/settings/tokens?type=beta) → **Fine-grained tokens**
2. Set **Resource owner** to your account
3. Set **Repository access** to "All repositories" (the agent creates new repos)
4. Under **Permissions → Repository permissions**, enable:
   | Permission | Access |
   |------------|--------|
   | **Administration** | Read and write _(needed for `gh repo create`)_ |
   | **Contents** | Read and write _(push code)_ |
   | **Issues** | Read and write _(read/post comments)_ |
   | **Metadata** | Read _(always required)_ |
   | **Workflows** | Read and write _(trigger Actions)_ |
5. Under **Permissions → Account permissions**, enable:
   | Permission | Access |
   |------------|--------|
   | **Administration** | Read and write _(create repos on your account)_ |
6. Copy the token (`github_pat_...`) and add it as `GH_PAT` in repository secrets

> **Classic token alternative:** If you prefer classic tokens, use scopes: `repo`, `workflow`, `delete_repo`

#### Getting a Vercel Token

1. Go to [vercel.com/account/tokens](https://vercel.com/account/tokens)
2. Create a new token with full access
3. Add it as `VERCEL_TOKEN` in repository secrets

### 3. Push the repository

```bash
git add -A
git commit -m "chore: initial setup"
git push origin main
```

---

## Usage

### Starting a session

1. Open a **New Issue** in this repository
2. Write your project specification in the issue body:
   ```
   # Project Name: my-cool-app

   Build a Next.js landing page with a hero section,
   feature cards, and a contact form that sends to...
   ```
3. Add the label **`agent-run`** to the issue
4. The workflow fires and the agent comments with its progress

### Sending follow-up instructions

Once the agent posts "✅ Initial code generated", simply add more comments:

```
Add a dark mode toggle to the navbar
```

```
Fix the contact form — it should validate email format
```

```
Add a footer with social media links
```

Each comment is fed to Aider, committed, pushed, and deployed automatically.

### Stopping the session

Post a comment containing:

```
!stop
```

The agent will post a summary and shut down the runner.

---

## File Structure

```
.
├── .github/workflows/
│   └── continuous-agent.yml   # GitHub Actions workflow
├── scripts/
│   ├── orchestrator.sh        # Main boot + polling loop
│   └── github_api.sh          # gh CLI helper functions
├── requirements.txt           # Python deps (aider-chat)
└── README.md                  # This file
```

---

## LLM Fallback Strategy

| Priority | Provider | Model | Trigger |
|----------|----------|-------|---------|
| Primary | Google Gemini | `gemini/gemini-2.5-flash-preview-05-20` | Default |
| Fallback | Groq | `groq/llama-3.3-70b-versatile` | When primary exits non-zero |

If the primary model fails (rate limit, timeout, server error), the orchestrator automatically retries the same instruction with the fallback model and posts a warning comment on the issue.

---

## Limitations

- **3-hour max:** GitHub Actions enforces a maximum job runtime of 6 hours, but this workflow is capped at 3 hours for cost control.
- **No parallel sessions:** Only one `agent-run` session runs at a time per issue.
- **Public repos only:** The agent creates public repositories by default. Modify `create_repo` in `github_api.sh` for private repos.
- **Vercel project linking:** The first deploy may require Vercel project setup. The agent uses `--yes` to accept defaults.

---

## Troubleshooting

| Problem | Solution |
|---------|----------|
| Workflow doesn't trigger | Ensure the label is exactly `agent-run` (case-sensitive) |
| `gh auth` fails | Check that `GH_PAT` is set and has the correct scopes |
| Vercel deploy fails | Verify `VERCEL_TOKEN` and that the project is linkable |
| Aider crashes repeatedly | Both models may be rate-limited; wait and retry |
| Bot comments on itself | The orchestrator filters its own comments by emoji markers |

---

## License

MIT
