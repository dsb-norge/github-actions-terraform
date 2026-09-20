# Planned with -refresh-only. Terraform words the empty result differently
# ("still matches the configuration") and the apply of that plan prints an
# ordinary zero summary line.
resource "terraform_data" "example" {
  input = "unchanged"
}
