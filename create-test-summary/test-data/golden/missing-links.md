### Terraform tests summary
❌ 1 failed · ✅ 1 passed — 2 files · 1 lane · ⏱ —

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-net.tftest.hcl` | unit | 1/2 | `0:03` |  |

<details><summary>❌ <code>tests/unit-net.tftest.hcl</code> — 1 of 2 run blocks failed</summary>

- `cidr` — Test assertion failed: wrong CIDR (`tests/unit-net.tftest.hcl:7`)

</details>

<details><summary>✅ <code>.</code> — 1 file · 1 passed · lane unit · ⏱ 0:12</summary>

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-app.tftest.hcl` | unit | 8/8 | `0:12` | [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-app) |

</details>

_Job links are unavailable: the run's jobs could not be read from the Jobs API._

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
