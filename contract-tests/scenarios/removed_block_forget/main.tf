# A removed block with destroy = false forgets the object: it leaves state
# but is not destroyed. The plan says "will no longer be managed by
# Terraform" and warns; neither the "Plan:" line nor the apply summary line
# carries a segment for it.
resource "terraform_data" "example_kept" {
  input = "kept"
}

removed {
  from = terraform_data.example_forgotten

  lifecycle {
    destroy = false
  }
}
