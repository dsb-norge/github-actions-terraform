# Fixtures for `parse-terraform-apply`

Every file here is the console of one `terraform apply` (or `terraform destroy`) invocation, as the `terraform-apply` action captures it: `-no-color`, `-input=false`, `TF_IN_AUTOMATION=true`, stdout and stderr together.

Two kinds of provenance:

- **Captured** — real output, produced by [`contract-tests/run.sh --capture`](../../contract-tests/run.sh) from the local-only scenario of the same name under [`contract-tests/scenarios/`](../../contract-tests/scenarios/). The terraform version is recorded below. The contract-test workflow re-runs the scenario against every supported terraform minor and fails when the summary-bearing lines drift from the fixture, so a captured fixture is never silently stale. Re-capture with `contract-tests/run.sh --capture <scenario>` and update the version column.
- **Hand-written** — assembled from real shapes (the resource addresses are synthetic), for cases a local-only configuration cannot produce: provider errors, ANSI colour, three-digit counts, verbs terraform does not print. The version column is `—` when the shape is version-independent, or the versions the shape is real for.

| Fixture | Provenance | Terraform | Shape it pins |
|---|---|---|---|
| `apply_adds_only.log` | captured (`adds_only`) | 1.16.2 | `Apply complete! Resources: 2 added, 0 changed, 0 destroyed.` |
| `apply_change_in_place.log` | captured (`change_in_place`) | 1.16.2 | `0 added, 1 changed, 0 destroyed`, followed by an `Outputs:` section |
| `apply_replace.log` | captured (`replace`) | 1.16.2 | a replacement counts as `1 added, 0 changed, 1 destroyed` |
| `apply_destroys_only.log` | captured (`destroys_only`) | 1.16.2 | a resource dropped from the configuration: `0 added, 0 changed, 1 destroyed` on an *apply* line |
| `apply_import_block.log` | captured (`import_block`) | 1.16.2 | `1 imported, 1 added, 0 changed, 0 destroyed` — the `imported` segment comes **first** (P32) |
| `apply_moved_block.log` | captured (`moved_block`) | 1.16.2 | a `moved` block leaves no trace on the summary line: `0 added, 0 changed, 0 destroyed` |
| `apply_removed_block_forget.log` | captured (`removed_block_forget`) | 1.16.2 | a `removed` block with `destroy = false` leaves no trace either — no `forgotten` segment (P36) |
| `apply_no_changes.log` | captured (`no_changes`) | 1.16.2 | `0 added, 0 changed, 0 destroyed` when there was nothing to do |
| `apply_outputs_only.log` | captured (`outputs_only`) | 1.16.2 | zero counts plus an `Outputs:` section carrying the new value |
| `apply_refresh_only.log` | captured (`refresh_only`) | 1.16.2 | a `-refresh-only` plan applied: an ordinary zero summary line |
| `apply_destroy_plan_applied.log` | captured (`destroy_plan_applied`) | 1.16.2 | a saved `-destroy` plan applied — what the default workflow's destroy step runs — prints **`Apply complete! … 2 destroyed`**, not `Destroy complete!` (P33) |
| `destroy_command_complete.log` | captured (`destroy_command`) | 1.16.2 | `terraform destroy`: the plan, then `Destroy complete! Resources: 1 destroyed.` |
| `apply_failed_provisioner.log` | captured (`failed_provisioner`) | 1.16.2 | a genuine partial apply — one resource created, one failed — with **no summary line** (P2) |
| `apply_cancelled_at_prompt.log` | captured (`cancelled_at_prompt`) | 1.16.2 | the approval prompt declined: `Apply cancelled.`, exit 1, no summary line |
| `apply_interrupted.log` | captured (`interrupted`) | 1.16.2 | SIGINT mid-apply: `Interrupt received.`, `Error: execution halted`, exit 1, no summary line |
| `apply_check_warnings.log` | captured (`check_warnings`) | 1.16.2 | a `Warning: Check block assertion failed` block between the progress lines and the summary line |
| `apply_progress_ticks.log` | captured (`progress_ticks`) | 1.16.2 | a real progress tick, `Still creating... [00m10s elapsed]` — the zero-padded form Terraform 1.12.0+ prints (#36368); 1.11 prints `[10s elapsed]` (P35) |
| `apply_complete_1_add_0_change_0_destroy.log` | hand-written | — | the plain summary line with a cloud resource address |
| `apply_complete_0_changes.log` | hand-written | — | the zero summary line alone |
| `apply_complete_with_outputs.log` | hand-written | — | parsing through a trailing `Outputs:` section |
| `apply_complete_with_imports.log` | hand-written | — | `5 imported, 0 added, 1 changed, 0 destroyed` — the P32 incident's line |
| `apply_complete_unknown_segment.log` | hand-written | — | a verb the parser does not know (`2 forgotten`) must be reported, not fail the parse — hypothetical for Terraform, but OpenTofu's real wording since 1.10 (`… N destroyed, M forgotten.`) (P36) |
| `apply_failed_partial.log` | hand-written | — | a provider error after two of three resources — no summary line |
| `apply_failed_immediately.log` | hand-written | — | a provider authentication error before anything was applied |
| `apply_large_counts.log` | hand-written | — | three-digit counts |
| `apply_non_ascii.log` | hand-written | — | UTF-8 resource keys survive the tick filter |
| `apply_summary_text_inside_output_value.log` | hand-written | — | the literal summary text inside an output value is not the summary line (P25) |
| `apply_with_progress_ticks.log` | hand-written | ≤1.11 | the tick forms Terraform printed up to 1.11 — `[10s elapsed]`, `[1h0m10s elapsed]`, `[id=…, 10s elapsed]` — real for those versions, not an older guess; 1.12+ pads to `[00m10s elapsed]` and renders hours as `[60m10s elapsed]` (P35) |
| `apply_ansi_coloured.log` | hand-written | — | colour codes precede a newline, so the summary line still parses (P26) |
| `destroy_complete_3_destroyed.log` | hand-written | — | `Destroy complete! Resources: 3 destroyed.` with `Still destroying…` ticks |
| `empty.log` | hand-written | — | an empty console |
