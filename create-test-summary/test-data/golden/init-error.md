### Terraform tests summary
❌ 1 failed — 1 file · 1 lane · ⏱ 0:30

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `modules/net/tests/unit-net.tftest.hcl` | unit | <span title="error (init)">error</span> | — | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/401#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/modules-net--unit-net) |

<details><summary>❌ <code>modules/net/tests/unit-net.tftest.hcl</code> — terraform init failed</summary>

- `terraform init` failed in `modules/net`; the job log's init step has the error. A syntax error in any test file of a root fails init for every test file there, so the cause may be a sibling of this file.

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
