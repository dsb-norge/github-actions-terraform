### Terraform tests summary
❌ 1 failed · ✅ 1 passed — 2 files · 2 lanes · ⏱ 2:45

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `modules/group/tests/integration-directory-group.tftest.hcl` | directory | 5/6 | `2:40` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/201#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/modules-group--integration-directory-group) |

<details><summary>❌ <code>modules/group/tests/integration-directory-group.tftest.hcl</code> — 1 of 6 run blocks failed</summary>

- `group_is_created` — Test assertion failed: group display name must start with `tftest-` (`modules/group/tests/integration-directory-group.tftest.hcl:42`)

</details>

<details><summary>✅ <code>.</code> — 1 file · 1 passed · lane unit · ⏱ 0:12</summary>

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-group.tftest.hcl` | unit | 8/8 | `0:12` | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/202#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-group) |

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
