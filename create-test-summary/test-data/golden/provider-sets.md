### Terraform tests summary
❌ 1 failed · ✅ 1 passed — 1 file · 1 lane · 2 provider sets · ⏱ 0:16

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-app.tftest.hcl` · providers from dev, staging | unit | 7/8 | `0:13` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/802#step:15:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-app--d4e5f6) |

<details><summary>❌ <code>tests/unit-app.tftest.hcl</code> — 1 of 8 run blocks failed · providers from dev, staging</summary>

- `sku` — Test assertion failed: sku (`tests/unit-app.tftest.hcl:3`)

</details>

<details><summary>✅ <code>.</code> — 1 file · 1 passed · lane unit · ⏱ 0:12 · providers from prod</summary>

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-app.tftest.hcl` | unit | 8/8 | `0:12` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/801#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-app--a1b2c3) |

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
