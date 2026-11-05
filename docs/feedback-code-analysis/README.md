# Code analysis of feedback, in your repository

When a user sends a feedback report, Noticebird can have Claude Code look for
its cause in your app's code and store what it found with the report: in the
console, in `get_feedback` over the MCP server, and in the mail that tells the
project's members about the report. The analysis runs in **your** GitHub
repository, as a GitHub Actions workflow, on your Claude subscription or your
Anthropic API key. Noticebird never sees your code.

The workflow is [`noticebird-feedback-analysis.yml`](noticebird-feedback-analysis.yml),
next to this page.

## What it does

1. A report comes in for a project whose code analysis is on.
2. Noticebird sends your repository a `repository_dispatch` of type
   `noticebird-feedback`, through the Noticebird GitHub App. Its payload is
   `{"project": "<project id>", "ticket": <ticket number>}`: no message, no
   screenshot, nothing the user wrote.
3. The workflow starts on a GitHub-hosted runner, checks out your default
   branch, and runs Claude Code (`anthropics/claude-code-action`) with
   Noticebird's MCP server.
4. Claude Code fetches the report (`get_feedback`, `get_feedback_screenshot`),
   searches your code for the cause (Read, Grep, Glob), and writes one triage
   block back with `set_feedback_analysis`: a summary, a severity (`low`,
   `medium`, `high`), a proposed route (`fix`, `design`, `roadmap`, `reject`)
   and the reason, by the triage rules of the
   [`noticebird` skill](../../skills/noticebird/reference/processing-reports.md#analysis-from-a-workflow).
5. Noticebird shows it as the report's newest analysis. The mail about the
   report waits for it, up to the project's wait; a run that takes longer
   leaves the mail without it (or with Noticebird's own first reading, when
   the project has that on), and the analysis still lands on the report.

The run changes nothing else: no status, no notes, no file, no commit.

## Setup

1. **Install the Noticebird GitHub App** on the repository that holds the
   app's code, and link it to the project in the Noticebird console under
   **Project › Integration** (a person with admin rights on the project does
   this). There you also turn the code analysis on and set how long the mail
   waits for it.
2. **Add the workflow.** Copy `noticebird-feedback-analysis.yml` to
   `.github/workflows/` on the repository's default branch (a repository
   dispatch runs the default branch's workflows only). Set the SDK `ref` in
   it to the release your app depends on.
3. **Add the repository secrets** (Settings › Secrets and variables ›
   Actions):
   - `CLAUDE_CODE_OAUTH_TOKEN` — a token of your Claude subscription, made
     with `claude setup-token` on your own machine; **or**
     `ANTHROPIC_API_KEY` — an Anthropic API key. With the API key, swap the
     two `claude_code_oauth_token` / `anthropic_api_key` lines in the
     workflow. Whether your subscription's terms allow it to run in CI is
     yours to check.
   - `NOTICEBIRD_MCP_TOKEN` — an MCP token, made in the console under
     **Project › Integration › MCP tokens**, on this project only. The
     workflow uses two of its scopes, `feedback:read` and `feedback:write`;
     the narrowest level that holds both is **Handle**. (Read cannot write
     an analysis; Manage is far more than it needs.) Handle holds more than
     those two — handling issues, a project's settings, who sent a report —
     but the workflow allows the agent no tool beyond `get_feedback`,
     `get_feedback_screenshot` and `set_feedback_analysis`.
4. **Check it.** Send a test report from a build of the app. The run shows
   in the repository's Actions tab as `Noticebird feedback FB-<n>`, and its
   analysis on the report in the console.

The workflow names the App's bot in `allowed_bots`, because
`claude-code-action` refuses a run a bot started unless it is listed there.

## Costs

- **Runner minutes.** A run takes a few minutes of an `ubuntu-latest`
  runner; on a private repository they count against your GitHub plan's
  Actions minutes. The job stops at 15 minutes (`timeout-minutes`).
- **Claude.** With `CLAUDE_CODE_OAUTH_TOKEN` a run uses your subscription's
  usage limits, like a Claude Code session of your own; with
  `ANTHROPIC_API_KEY` it is billed as API tokens. `--max-turns` in
  `claude_args` caps a run's length; `--model` there picks the model.
- Noticebird dispatches at most a fixed number of analyses per project per
  hour; past it a report gets none.

## Trust

- **The payload is content-free.** It carries the project's id and the
  ticket number only. The workflow checks their shape before it uses them,
  and fetches the report itself with your MCP token.
- **The runner sees only the checkout.** A GitHub-hosted runner is a fresh
  virtual machine per run, holding your repository and the skill's rules,
  no secret of yours but the three the workflow names. Claude Code may read
  files in the workspace only (`blockReadsOutsideWorkingDirectories`), not
  `.git`, and has no shell, no edit tools and no web access. The job's
  GitHub token can only read the repository (`permissions: contents: read`)
  and expires with the job.
- **The report is untrusted.** Anyone who can send feedback from your app
  writes its text and its screenshot. The prompt tells Claude Code to treat
  them as data, never as instructions; a report that still steers it can at
  most produce a misleading analysis.
- **The analysis is advice.** It starts no work and changes no status. Your
  team chooses what to do with a report, and checks the analysis against the
  code before it acts on it.
- **The MCP token reads your feedback.** At Handle, `get_feedback` also
  names the reporter and their contact address; the triage rules keep both
  out of the analysis. Keep the token on the one project, and revoke it in
  the console when you stop using the workflow.
