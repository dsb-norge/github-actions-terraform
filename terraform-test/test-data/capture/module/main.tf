terraform {
  required_providers {
    random = { source = "hashicorp/random", version = ">= 3.0" }
    null   = { source = "hashicorp/null", version = ">= 3.0" }
  }
}
variable "prefix" {
  type    = string
  default = "tftest"
  validation {
    condition     = length(var.prefix) > 2
    error_message = "prefix must be longer than 2 characters"
  }
}
resource "random_pet" "this" { prefix = var.prefix }
resource "null_resource" "this" {
  triggers = { name = random_pet.this.id }
  lifecycle {
    postcondition {
      condition     = var.prefix != "boom"
      error_message = "prefix must not be boom"
    }
  }
}
output "name" { value = random_pet.this.id }
