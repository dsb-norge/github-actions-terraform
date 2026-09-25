### Terraform tests summary
❌ 1 failed — 1 file · 1 lane · ⏱ 0:09

**❌ Failed (1)**

| Test file | Lane | Runs | Time | Links |
|---|:---:|:---:|:---:|---|
| `modules/group/tests/integration-directory-group.tftest.hcl` | directory | <span title="error (no-credentials)">error</span> | — | [job log](https://github.com/dsb-norge/test-repo/actions/runs/4242/job/501#step:14:1) · [output](https://github.com/dsb-norge/test-repo/actions/runs/4242/artifacts/modules-group--integration-directory-group) |

<details><summary>❌ <code>modules/group/tests/integration-directory-group.tftest.hcl</code> — no credentials in <code>tftest-directory</code></summary>

The lane's GitHub Environment `tftest-directory` has no `ARM_TENANT_ID` or `ARM_CLIENT_ID`. A collaborator with write access sets the secrets, the identity's owner adds a federated credential for the environment's subject, then the failed jobs are re-run ([bring-up](https://github.com/dsb-norge/github-actions-terraform/blob/main/docs/Terraform-tests.md#36-github-environments-per-lane)):

```bash
gh secret set ARM_TENANT_ID       --repo dsb-norge/test-repo --env tftest-directory --body '<tenant-id>'
gh secret set ARM_CLIENT_ID       --repo dsb-norge/test-repo --env tftest-directory --body '<client-id>'
gh secret set ARM_SUBSCRIPTION_ID --repo dsb-norge/test-repo --env tftest-directory --body '<subscription-id>'   # subscription lanes only
gh secret list --repo dsb-norge/test-repo --env tftest-directory
gh run rerun 4242 --repo dsb-norge/test-repo --failed
```

</details>

[Workflow log](https://github.com/dsb-norge/test-repo/actions/runs/4242)
