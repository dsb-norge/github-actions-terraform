variable "needed" {}
run "uses_required_var" {
  command = plan
  variables { prefix = var.needed }
}
