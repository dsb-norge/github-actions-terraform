run "first_passes" {
  command = plan
}
run "postcondition_errors" {
  variables { prefix = "boom" }
}
run "after_error" {
  command = plan
}
