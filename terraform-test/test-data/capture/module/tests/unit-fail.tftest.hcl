run "prefix_is_wrong" {
  command = plan
  assert {
    condition     = random_pet.this.prefix == "wrong"
    error_message = "group display name must start with tftest-"
  }
}
run "still_passes" {
  command = plan
  assert {
    condition     = random_pet.this.prefix == "tftest"
    error_message = "prefix should default to tftest"
  }
}
