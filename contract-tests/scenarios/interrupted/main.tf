# SIGINT during a slow apply (a job cancelled from the GitHub UI delivers the
# same signal). Terraform prints "Interrupt received", halts, and exits 1
# with no summary line.
#
# The provisioner's own error line ends in either "signal: killed" or
# "signal: interrupt", depending on whether terraform's cancellation or the
# forwarded SIGINT reaches the sleep first — a race, so that line is
# deliberately outside the signature run.sh compares (it starts with "Error
# running", not "Error: ").
resource "terraform_data" "example_slow" {
  input = "slow"

  provisioner "local-exec" {
    command = "sleep 30"
  }
}
