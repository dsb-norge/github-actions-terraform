# A moved block renames a resource in state. The plan reports "has moved to"
# and no count on its "Plan:" line; the apply summary line does not mention
# the move at all.
resource "terraform_data" "example_new_name" {
  input = "stable"
}

moved {
  from = terraform_data.example_old_name
  to   = terraform_data.example_new_name
}
