run "plans_with_default_prefix" {
  command = plan
  assert {
    condition     = random_pet.this.prefix == "tftest"
    error_message = "prefix should default to tftest"
  }
}
run "applies_with_custom_prefix" {
  variables { prefix = "custom" }
  assert {
    condition     = startswith(output.name, "custom-")
    error_message = "name must start with the prefix"
  }
}
