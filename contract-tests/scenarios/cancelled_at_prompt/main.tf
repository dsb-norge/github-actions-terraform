# 'terraform apply' without -auto-approve, answered "no" at the prompt:
# "Apply cancelled." and exit 1, no summary line. Not a shape the default
# workflow can produce (it applies saved plans), pinned so the parser's
# answer to it is known.
resource "terraform_data" "example" {
  input = "never applied"
}
