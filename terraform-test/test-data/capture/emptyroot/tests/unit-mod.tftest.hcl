mock_provider "random" {}
mock_provider "null" {}
run "plans_module" {
  command = apply
  module { source = "./mod" }
  assert {
    condition     = random_pet.this.prefix == "tftest"
    error_message = "prefix should default to tftest"
  }
}
