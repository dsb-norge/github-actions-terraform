### Terraform tests summary
⚠️ 1 tolerated · ✅ 1 passed — 2 files · 2 lanes · ⏱ 1:10

**⚠️ Tolerated (1)**

| Test file | Lane | Result | Runs | Time | Links |
|---|:---:|:---:|:---:|:---:|---|
| `modules/rg/tests/integration-subscription-rg.tftest.hcl` | subscription | <span title="error (run): allowed to fail">⚠️ error</span> | 2/4 | `1:05` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/301#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/modules-rg--integration-subscription-rg) |

<details><summary>⚠️ <code>modules/rg/tests/integration-subscription-rg.tftest.hcl</code> — 1 error, 1 skipped</summary>

- `assign_role` — Error: authorization failed for the principal (`modules/rg/main.tf:31`)
- `verify_role` — skipped: a previous run block errored

</details>

<details><summary>✅ <code>.</code> — 1 file · 1 passed · lane unit · ⏱ 0:12</summary>

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-app.tftest.hcl` | unit | 8/8 | `0:12` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/302#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-app) |

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
