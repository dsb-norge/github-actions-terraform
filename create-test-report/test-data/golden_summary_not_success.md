### Terraform test summary for file: `main.tftest.hcl`
|  | Step | Result |
|:---:|---|---|
| ⚙️ | Initialization | `success` |
| 🧪 | Tests | <kbd>failure</kbd> |

<b>Test summary: ❌ "Error: test run aborted"</b>
<details><summary>Show Test Report</summary>

```terraform
Test result for file: main.tftest.hcl
overall result: failure
exit code: -1
 
output: 
Test: "basic_create" -----> "pass" ✅ 
Test: "basic_update" -----> "error" ❌ 
See error details below: 
  
  | File: "tests/main.tftest.hcl"
  | Resource: "azurerm_thing.x"
  | Message: "Invalid value for variable"
  
==================== Test summary for file: "Failure! 1 passed, 1 failed." ====================
```
</details>

*Pusher: @octo-user, Action: `pull_request`, Workflow: `DSB Terraform Module CI`*