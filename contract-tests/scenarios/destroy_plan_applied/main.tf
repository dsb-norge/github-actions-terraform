# The default workflow's destroy is 'terraform plan -destroy -out=<file>'
# followed by 'terraform apply <file>'. Applying a saved destroy plan prints
# "Apply complete! Resources: 0 added, 0 changed, N destroyed." — NOT
# "Destroy complete!", which only 'terraform destroy' prints
# (docs/Apply-and-destroy-reporting.md P33).
resource "terraform_data" "example_first" {
  input = "first"
}

resource "terraform_data" "example_second" {
  input = "second"
}
