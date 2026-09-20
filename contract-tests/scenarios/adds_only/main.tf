# Two resources created from an empty state. The plainest summary line
# terraform prints: "Apply complete! Resources: 2 added, 0 changed, 0 destroyed."
resource "terraform_data" "example_first" {
  input = "first"
}

resource "terraform_data" "example_second" {
  input = "second"
}
