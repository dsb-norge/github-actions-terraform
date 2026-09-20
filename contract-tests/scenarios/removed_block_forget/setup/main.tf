resource "terraform_data" "example_kept" {
  input = "kept"
}

resource "terraform_data" "example_forgotten" {
  input = "forgotten"
}
