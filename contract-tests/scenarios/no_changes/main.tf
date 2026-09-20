# Identical to the setup configuration: the plan prints "No changes." (and
# exits 0 under -detailed-exitcode), the apply still prints a summary line.
resource "terraform_data" "example" {
  input = "unchanged"
}
