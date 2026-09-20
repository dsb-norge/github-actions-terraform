# Fixtures for `parse-terraform-plan`

Every file here is the console of one `terraform plan` invocation, as the `terraform-plan` action captures it: `-detailed-exitcode`, `-no-color`, `-input=false`, `-out=<file>`, `TF_IN_AUTOMATION=true`, stdout and stderr together.

Three kinds of provenance:

- **Captured** — real output, produced by [`contract-tests/run.sh --capture`](../../contract-tests/run.sh) from the local-only scenario of the same name under [`contract-tests/scenarios/`](../../contract-tests/scenarios/). The terraform version is recorded below. The contract-test workflow re-runs the scenario against every supported terraform minor and fails when the summary-bearing lines drift from the fixture. Re-capture with `contract-tests/run.sh --capture <scenario>` and update the version column.
- **Sanitised** — real plans from calling repositories with identifiers replaced, added before the contract tests existed. The terraform version was not recorded. They cover provider-shaped output (data reads, modules, large plans) that a local-only configuration cannot produce.
- **Hand-written** — assembled from real shapes (the resource addresses are synthetic), for a shape no local-only configuration can produce because the language feature has no built-in implementation. The version column names the versions the shape is real for.

Wording established by the captures, for the record:

- Imports are a segment of the `Plan:` line and come **first**: `Plan: 1 to import, 1 to add, 0 to change, 0 to destroy.`
- Moves and removals have **no** segment on the `Plan:` line. They are counted from the resource lines — `# a has moved to b` and `# a will no longer be managed by Terraform, but will not be destroyed` — and a removal also prints `Warning: Some objects will no longer be managed by Terraform`.
- An output-only plan prints **no** `Plan:` line: only `Changes to Outputs:` and the sentence `…without changing any real infrastructure.`, and exits 2.
- A `-refresh-only` plan with nothing drifted says `No changes. Your infrastructure still matches the configuration.` — a different sentence from the ordinary `No changes. Your infrastructure matches the configuration.`

| Fixture | Provenance | Terraform | Shape it pins |
|---|---|---|---|
| `plan_adds_only.log` | captured (`adds_only`) | 1.16.2 | `Plan: 2 to add, 0 to change, 0 to destroy.` |
| `plan_change_in_place.log` | captured (`change_in_place`) | 1.16.2 | `0 to add, 1 to change, 0 to destroy` plus `Changes to Outputs:` — not output-only |
| `plan_replace.log` | captured (`replace`) | 1.16.2 | `must be replaced` → `1 to add, 0 to change, 1 to destroy` |
| `plan_destroys_only.log` | captured (`destroys_only`) | 1.16.2 | `0 to add, 0 to change, 1 to destroy` |
| `plan_import_block.log` | captured (`import_block`) | 1.16.2 | `Plan: 1 to import, 1 to add, 0 to change, 0 to destroy.` |
| `plan_moved_block.log` | captured (`moved_block`) | 1.16.2 | `has moved to` with a zero `Plan:` line |
| `plan_removed_block_forget.log` | captured (`removed_block_forget`) | 1.16.2 | `will no longer be managed by Terraform, but will not be destroyed`, a zero `Plan:` line and the warning |
| `plan_no_changes.log` | captured (`no_changes`) | 1.16.2 | `No changes. Your infrastructure matches the configuration.`, exit 0 |
| `plan_outputs_only.log` | captured (`outputs_only`) | 1.16.2 | no `Plan:` line; `Changes to Outputs:`; exit 2 |
| `plan_refresh_only.log` | captured (`refresh_only`) | 1.16.2 | `No changes. Your infrastructure still matches the configuration.`, exit 0 |
| `plan_destroy_plan_applied.log` | captured (`destroy_plan_applied`) | 1.16.2 | a `-destroy` plan: `0 to add, 0 to change, 2 to destroy` |
| `plan_failed_provisioner.log` | captured (`failed_provisioner`) | 1.16.2 | the ordinary plan of an apply that later fails |
| `plan_interrupted.log` | captured (`interrupted`) | 1.16.2 | the ordinary plan of an apply later interrupted |
| `plan_check_warnings.log` | captured (`check_warnings`) | 1.16.2 | `Warning: Check block assertion failed` after the `Plan:` line |
| `plan_progress_ticks.log` | captured (`progress_ticks`) | 1.16.2 | the plan of a slow create |
| `plan_with_actions.log` | hand-written | 1.14+ | `Plan: 1 to add, 0 to change, 0 to destroy. Actions: 2 to invoke.` — the actions sentence Terraform 1.14+ appends after the counts (#37689) does not disturb the per-segment regexes (P37); no built-in action type exists to capture from |
| `plan_0_changes.log` | sanitised | — | `No changes.` with many refreshed resources |
| `plan_0_changes_with_data_read.log` | sanitised | — | a deferred data read with a zero `Plan:` line and the words `Changes to Outputs:` inside a heredoc value |
| `plan_1_change.log` | sanitised | — | one in-place change in a large plan |
| `plan_1_change_with_output_changes.log` | sanitised | — | a resource change alongside output changes — not output-only |
| `plan_1_add_1_change_5_destroy_2_move.log` | sanitised | — | both move forms: `has moved to` and `(moved from` |
| `plan_14_add_21_change_0_destroy_14_removed_and_not_destroyed.log` | sanitised | — | fourteen `will no longer be managed by Terraform` resources |
| `plan_output_only_changes.log` | sanitised | — | output-only changes |
| `plan_output_only_changes_with_data_read.log` | sanitised | — | output-only changes alongside a deferred data read: a zero `Plan:` line and no "without changing" sentence |
