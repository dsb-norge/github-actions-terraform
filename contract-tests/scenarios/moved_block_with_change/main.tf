# A move AND an in-place change in the same plan. Terraform renders this as one
# resource block carrying both — the "(moved from ...)" form rather than the
# separate "# a has moved to b" comment line that moved_block pins — so the plan
# parser counts the move from a different string and the change from the
# "Plan:" line. Both have to land: move 1 + change 1 = total 2.
#
# The apply summary line still says nothing about the move: "0 added, 1 changed,
# 0 destroyed" (P36). The apply total is therefore 1 while the plan total is 2,
# which is correct and is the point of pinning it.
resource "terraform_data" "new" {
  input = "generation-2"
}

moved {
  from = terraform_data.old
  to   = terraform_data.new
}
