# A check block whose assertion fails produces a warning — without any
# provider. Terraform prints it in the plan and again in the apply, where it
# sits between the progress lines and the summary line, so the parsers must
# read through it.
resource "terraform_data" "example" {
  input = "generation-2"
}

check "example_input_is_expected" {
  assert {
    condition     = terraform_data.example.input == "something else"
    error_message = "Input is not what the check expects; this warning is intentional."
  }
}
