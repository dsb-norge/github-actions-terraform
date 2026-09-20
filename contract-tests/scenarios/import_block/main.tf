# An import block adopts an existing object, and a second resource is created
# in the same run. Terraform puts the "imported" segment BEFORE "added" on the
# summary line — the shape that once made a successful apply render as failed
# (docs/Apply-and-destroy-reporting.md P32).
#
# That terraform_data can be imported at all is observed behaviour, not
# documented: the built-in provider ships a minimal importer that takes the
# id verbatim. Import blocks need terraform 1.5 (expected.json: min-terraform).
import {
  to = terraform_data.example_adopted
  id = "adopted-0001"
}

resource "terraform_data" "example_adopted" {}

resource "terraform_data" "example_created" {
  input = "created alongside the import"
}
