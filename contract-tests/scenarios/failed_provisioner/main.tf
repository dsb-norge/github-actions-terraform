# A genuine partial apply: the first resource is created, the second fails
# in a provisioner. Terraform prints the error and no summary line at all —
# the case where counts must be '?' and never zeros (P2).
resource "terraform_data" "example_ok" {
  input = "fine"
}

resource "terraform_data" "example_broken" {
  input = "breaks"

  provisioner "local-exec" {
    command = "echo 'simulated provider failure' >&2; exit 1"
  }
}
