# A changed triggers_replace forces a destroy-and-create of the same
# address: "must be replaced" in the plan, and an apply summary that counts
# both an add and a destroy for one resource.
resource "terraform_data" "example" {
  triggers_replace = ["generation-2"]
}
