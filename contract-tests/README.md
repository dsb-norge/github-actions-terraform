# Contract tests — real terraform against the console parsers

`parse-terraform-plan` and `parse-terraform-apply` read terraform's console
output. Their unit suites pin that output as fixtures; nothing in a unit suite
can tell whether the fixture is still what terraform prints. This directory
does: it runs a set of local-only terraform configurations under every
supported terraform minor, captures the console exactly as the actions do,
feeds it through the two parsers, and compares the summary-bearing lines
against the pinned fixtures. A wording change in a new release fails the job
and names the line.

Spec: [docs/Apply-and-destroy-reporting.md §16](../docs/Apply-and-destroy-reporting.md).
Workflow: [`.github/workflows/terraform-contract-tests.yml`](../.github/workflows/terraform-contract-tests.yml).

## Running it

```bash
# every scenario, with the terraform on PATH
contract-tests/run.sh

# one scenario
contract-tests/run.sh import_block

# a different binary
TF_BIN=/opt/terraform/1.11.4/terraform contract-tests/run.sh
```

It prints one line per scenario with the plan and apply summary lines terraform
produced, the canonical `Tests run / passed / failed` lines (plus a `skipped`
line when a version floor applied), and — under GitHub Actions — a table in the
job summary and an `::error` per failure. By hand, the scratch directory is
removed when every scenario passed and kept, with its path printed, when one
failed; set `RUNNER_TEMP` to choose it yourself (it is then never removed).

No providers are downloaded: every scenario uses the built-in `terraform_data`
resource (which supports `import`, `moved` and `removed` blocks), so `init` is
offline and the whole run takes about a minute.

## Layout

```
contract-tests/
├── README.md              this file
├── run.sh                 the runner (local and CI)
├── versions.json          the version window — the ONE place it lives
├── resolve-versions.sh    turns versions.json into a matrix via the releases API
└── scenarios/<name>/
    ├── main.tf            the configuration whose plan + apply are captured
    ├── setup/main.tf      optional: applied first, to create the prior state
    └── expected.json      operation, expected parser outputs, fixture paths
```

A scenario's `expected.json`:

| Key | Meaning |
|---|---|
| `operation` | `apply` (plan, then apply the saved plan — the workflow's path), `refresh-only`, `destroy-plan` (a saved `-destroy` plan applied), `destroy` (`terraform destroy`), `prompt-decline` (answer `no` at the approval prompt), `interrupt` (SIGINT five seconds into the apply) |
| `min-terraform` | optional; the oldest terraform the scenario's language feature exists on (`import` blocks: 1.5, `removed` blocks: 1.7). Below it the scenario is skipped with a one-line note, counted as neither passed nor failed, and listed as skipped in the summary — the window does not stop at 1.7 forever |
| `plan` | expected `parse-terraform-plan` outputs and the plan's exit code; `null` when the operation has no separate plan console |
| `apply` | expected `parse-terraform-apply` outputs and the apply's exit code; `"ticks": true` additionally asserts a real progress-tick line was printed and filtered |
| `*.fixture` | repo-relative path of the pinned console under the parser's `test-data/` |

## Adding a scenario

1. Create `scenarios/<name>/main.tf` (and `setup/main.tf` if it needs prior
   state) and `expected.json` with the counts you expect and fixture paths under
   `parse-terraform-plan/test-data/` and `parse-terraform-apply/test-data/`.
2. `contract-tests/run.sh --capture <name>` — runs it, checks the counts, and
   writes the fixtures.
3. Add the fixtures to the two parsers' `run_all_tests.sh` and to the
   `README.md` next to them, with the terraform version you captured with.

## What is compared

Only the summary-bearing lines: `Plan:`, `Apply complete!`, `No changes.`,
`Changes to Outputs:`, every `Warning:` and `Error:` line, the per-resource
action lines (`will be created`, `has moved to`, …) and the progress-tick shape
with its elapsed time normalised. Resource ids, durations and the order two
parallel creates finish in are noise and are not compared.

`Warning:` lines being in the signature means a new release that prints a new
warning — a deprecation notice, say — in every console **fails every scenario
at once, on purpose**: that same warning would land in every calling
repository's PR comment through `parse-terraform-warnings`, and re-pinning is
how it gets acknowledged rather than discovered there.

## When the workflow fails

The `::error` names the scenario and the terraform version, then lists the
lines that version emits which the fixture lacks and the lines the fixture has
which that version no longer emits. The last forty lines of each console are
in the job log right under the failure, and the whole scratch directory —
consoles, parser logs, state, plan files — is uploaded as the
`contract-tests-<version>` artifact (kept seven days). Decide which is right:

- **Terraform changed its wording and the parser still counts correctly** —
  re-pin: `contract-tests/run.sh --capture <name>` with that terraform version,
  update the version column in the fixture README, commit.
- **The parser no longer counts correctly** — that is a parser bug surfaced
  early; fix the parser, then re-pin.
- **The counts assertion failed on one version only** — read the captured
  console in the job log or the artifact; the scenario may need a
  `min-terraform` floor in its `expected.json`.

Two things about the scheduled run worth knowing before it bites:

- GitHub sends the failure notification to the user who **last edited the
  `cron` line** in the workflow file, not to the committer of the change that
  broke it.
- On a public repository GitHub **disables a scheduled workflow after 60 days
  without repository activity**. Re-enable it with
  `gh workflow enable "Terraform contract tests"`.

## The version window

`versions.json`:

```json
{
  "newest-minors": 6,
  "extra": []
}
```

- `newest-minors` — how many of the newest minor series run, each at its latest
  patch. The newest minor is always included, so `latest` is always covered.
  Six spans every version the calling repositories pin.
- `extra` — exact versions to run in addition, for a caller pinned below the
  window. Usually empty; drop an entry when its caller has moved on.

Nothing names a release. `resolve-versions.sh` resolves the window against the
HashiCorp releases API at run time, skipping pre-releases, so a new minor enters
the matrix on the next run and the oldest drops out. The weekly schedule is what
catches a new release without anyone pushing. The resolver fails the job loudly
when the API is unreachable or returns fewer minors than the window asks for —
this workflow is not a required check, so a silently empty matrix would be a
green run that tested nothing.
