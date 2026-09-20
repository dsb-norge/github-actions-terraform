# Only an output is added. Terraform prints no "Plan:" line at all — just
# "Changes to Outputs:" and the "without changing any real infrastructure"
# sentence — yet exits 2, and the apply prints an Outputs section with the
# value (the P3 exposure the renderer strips by default).
resource "terraform_data" "example" {
  input = "unchanged"
}

output "example_greeting" {
  value = "hello from the contract tests"
}
