resource "terraform_data" "example_kept" {
  input = "kept"
}

resource "terraform_data" "example_removed" {
  input = "removed"
}
