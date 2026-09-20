# One of two resources is dropped from the configuration, so a normal apply
# destroys it: "0 added, 0 changed, 1 destroyed" on an *apply* summary line.
resource "terraform_data" "example_kept" {
  input = "kept"
}
