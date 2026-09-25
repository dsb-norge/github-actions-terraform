### Terraform tests summary
❌ 1 failed — 1 file · 1 lane · ⏱ 0:09

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `tests/unit-app.tftest.hcl` | unit | <span title="error (lock-platform)">error</span> | — | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/551#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/root--unit-app) |

<details><summary>❌ <code>tests/unit-app.tftest.hcl</code> — the provider lock records no checksum for the runner's platform</summary>

The provider lock `envs/prod/.terraform.lock.hcl` records no `h1:` checksum for the runner's platform `linux_amd64`. Add it where the lock lives (after `terraform init` there) and commit the lock; every environment of this provider set needs it: `prod`, `staging`:

```bash
terraform -chdir=envs/prod providers lock -platform=linux_amd64
```

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
