# A destroy plan with nothing to destroy: no prior state, no resources. The
# plan prints "No changes. No objects need to be destroyed." — a third "No
# changes." sentence, distinct from the ordinary one and from -refresh-only's
# — and exits 0, not 2. Applying it still prints a full summary line, "Apply
# complete! Resources: 0 added, 0 changed, 0 destroyed.", so the empty destroy
# the default workflow runs when an environment is already gone reports as a
# completed apply with zero counts rather than as an unparsable console.
#
# There is deliberately no resource and no setup: an empty configuration is
# what the scenario is about.
terraform {}
