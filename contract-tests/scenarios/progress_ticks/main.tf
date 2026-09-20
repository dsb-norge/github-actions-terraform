# A create that takes longer than terraform's 10-second progress interval,
# so the console carries a real "Still creating... [<elapsed>]" tick line.
# Pins the tick filter (P5) against real output rather than a hand-written
# line — the elapsed format has already changed once (P35).
resource "terraform_data" "example_slow" {
  input = "slow"

  provisioner "local-exec" {
    command = "sleep 11"
  }
}
