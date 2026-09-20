# The resource's input changes, which terraform_data applies as an in-place
# update, and an output that depends on it changes with it. The plan therefore
# carries both a "Plan:" line and a "Changes to Outputs:" section — a plan
# that touches resources AND outputs must not be reported as output-only.
resource "terraform_data" "example" {
  input = "generation-2"
}

output "example_output" {
  value = terraform_data.example.output
}
