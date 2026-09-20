# 'terraform destroy -auto-approve' — the one invocation that prints
# "Destroy complete! Resources: N destroyed." Its console also carries the
# plan it made, so there is no separate plan console for this scenario.
resource "terraform_data" "example" {
  input = "doomed"
}
