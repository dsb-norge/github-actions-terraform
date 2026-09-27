# Fixtures for `parse-terraform-plan`

Every `.log` file here is the console of one `terraform plan` invocation, as the `terraform-plan` action captures it: `-detailed-exitcode`, `-no-color`, `-input=false`, `-out=<file>`, `TF_IN_AUTOMATION=true`, stdout and stderr together. Every `.json` file is the `terraform show -json` of a saved plan, next to the console of the same plan (the `plan_json_*` pairs below).

Four kinds of provenance:

- **Captured** — real output, produced by [`contract-tests/run.sh --capture`](../../contract-tests/run.sh) from the local-only scenario of the same name under [`contract-tests/scenarios/`](../../contract-tests/scenarios/). The terraform version is recorded below. The contract-test workflow re-runs the scenario against every supported terraform minor and fails when the summary-bearing lines drift from the fixture. Re-capture with `contract-tests/run.sh --capture <scenario>` and update the version column.
- **Sanitised** — real plans from calling repositories with identifiers replaced, added before the contract tests existed. The terraform version was not recorded. They cover provider-shaped output (data reads, modules, large plans) that a local-only configuration cannot produce.
- **Hand-written** — assembled from real shapes (the resource addresses are synthetic), for a shape no local-only configuration can produce because the language feature has no built-in implementation. The version column names the versions the shape is real for.
- **Captured pair** — the `plan_json_*` fixtures: a real console (`.log`) and the `terraform show -json` of the same saved plan (`.json`), captured by hand from small credential-free lab configurations (`terraform_data`, plus `hashicorp/random` and `hashicorp/local` where noted), not by the contract tests. Nothing was edited or replaced; the ids are random values from the lab. They pin what the console parser reads beside what the JSON plan holds for the same plan. `injected_summary`, `no_changes`, `outputs_only`, `destroy_plan` and `data_read` were captured without `TF_IN_AUTOMATION`, so their consoles end with the `Saved the plan to:` hint, which no parser reads; `targeted_incomplete` and `errored` were captured with the action's full command line.

In a JSON plan, established by the captured pairs:

- Each `resource_changes[]` entry carries `mode` (`managed` or `data`) and `change.actions`: `["create"]`, `["update"]`, `["delete"]`, `["delete","create"]` for a replacement, `["forget"]` for a `removed` block, `["read"]` for a data source, `["no-op"]` for an unchanged resource.
- An import carries `change.importing` (`{"id": …}`), whatever its actions: in `injected_summary` the imported resource is also replaced, `["delete","create"]`.
- A move carries `previous_address`, whatever its actions: in `injected_summary` the moved resource is also updated.
- `output_changes` holds every output with its actions; an unchanged one is `["no-op"]`.
- A `-target` plan says `"complete": false`. A plan that fails after planning some changes still writes its plan file (plan exit 1), and the JSON says `"errored": true` and `"complete": false`.

Wording established by the captures, for the record:

- Imports are a segment of the `Plan:` line and come **first**: `Plan: 1 to import, 1 to add, 0 to change, 0 to destroy.`
- Moves and removals have **no** segment on the `Plan:` line. They are counted from the resource lines — `# a has moved to b` and `# a will no longer be managed by Terraform, but will not be destroyed` — and a removal also prints `Warning: Some objects will no longer be managed by Terraform`.
- An output-only plan prints **no** `Plan:` line: only `Changes to Outputs:` and the sentence `…without changing any real infrastructure.`, and exits 2.
- A `-refresh-only` plan with nothing drifted says `No changes. Your infrastructure still matches the configuration.` — a different sentence from the ordinary `No changes. Your infrastructure matches the configuration.`
- A `-destroy` plan with nothing to destroy says `No changes. No objects need to be destroyed.` and exits **0** — a third `No changes.` sentence, and the only plan console with no `Plan:` line that is not output-only.
- A move whose resource also changes is rendered as `# a will be updated in-place` followed by `# (moved from b)` on its own line, not as `# b has moved to a`. Both forms count as one move.

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
| `plan_moved_block_with_change.log` | captured (`moved_block_with_change`) | 1.16.2 | a move **and** an in-place change on the same resource: the `(moved from` form plus `0 to add, 1 to change, 0 to destroy` — move 1 + change 1 = total 2 |
| `plan_destroy_plan_empty.log` | captured (`destroy_plan_empty`) | 1.16.2 | a `-destroy` plan of an empty configuration: `No changes. No objects need to be destroyed.`, exit 0 |
| `plan_with_actions.log` | hand-written | 1.14+ | `Plan: 1 to add, 0 to change, 0 to destroy. Actions: 2 to invoke.` — the actions sentence Terraform 1.14+ appends after the counts (#37689) does not disturb the per-segment regexes (P38); no built-in action type exists to capture from |
| `plan_0_changes.log` | sanitised | — | `No changes.` with many refreshed resources |
| `plan_0_changes_with_data_read.log` | sanitised | — | a deferred data read with a zero `Plan:` line and the words `Changes to Outputs:` inside a heredoc value |
| `plan_1_change.log` | sanitised | — | one in-place change in a large plan |
| `plan_1_change_with_output_changes.log` | sanitised | — | a resource change alongside output changes — not output-only |
| `plan_1_add_1_change_5_destroy_2_move.log` | sanitised | — | both move forms: `has moved to` and `(moved from` |
| `plan_14_add_21_change_0_destroy_14_removed_and_not_destroyed.log` | sanitised | — | fourteen `will no longer be managed by Terraform` resources |
| `plan_output_only_changes.log` | sanitised | — | output-only changes |
| `plan_output_only_changes_with_data_read.log` | sanitised | — | output-only changes alongside a deferred data read: a zero `Plan:` line and no "without changing" sentence |
| `plan_json_injected_summary.{log,json}` | captured pair (`random` too) | 1.16.2 | imports 1 (also replaced), adds 3, changes 2, destroys 3, moves 1 (also updated), forgets 1; one value reads `No changes allowed; Plan: 0 to add, 0 to change, 0 to destroy.`, so the console parser reads import, add, change and destroy as 0 |
| `plan_json_no_changes.{log,json}` | captured pair (`random` too) | 1.16.2 | `No changes.`; every resource and the output `["no-op"]` |
| `plan_json_outputs_only.{log,json}` | captured pair (`random` too) | 1.16.2 | a new output and nothing else: `output_changes` holds a `["create"]` beside a `["no-op"]`, every resource `["no-op"]` |
| `plan_json_destroy_plan.{log,json}` | captured pair (`random` too) | 1.16.2 | a `-destroy` plan: four `["delete"]`, the output `["delete"]` |
| `plan_json_data_read.{log,json}` | captured pair (`random`, `local`) | 1.16.2 | a deferred data-source read (`mode: data`, `["read"]`) beside a replacement, an update and a create, and an output change |
| `plan_json_targeted_incomplete.{log,json}` | captured pair | 1.16.2 | a `-target` plan: `complete: false`, one `["update"]`, the targeting warning |
| `plan_json_errored.{log,json}` | captured pair | 1.16.2 | a failed precondition after one update was planned: `Plan: 0 to add, 1 to change, 0 to destroy.` then `Error:`, plan exit 1; `errored: true`, `complete: false` |
