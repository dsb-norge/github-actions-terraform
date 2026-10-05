# Module dependencies

How a Terraform **module** repository constrains, updates, tests and releases its dependencies,
and what a developer does when. It applies to repositories on
[`terraform-module-ci`](Workflow-terraform-module-ci.md). A repository of environments, a root
module, works the other way round: it commits its lock file and pins narrowly, see
[Dependabot-admission.md](Dependabot-admission.md).

## 1. The rules

- **A provider gets a range over one major**, written `>= <floor>, < <next major>.0.0`:

  ```hcl
  terraform {
    required_providers {
      azurerm = {
        source  = "hashicorp/azurerm"
        version = ">= 4.0.0, < 5.0.0"
      }
    }
  }
  ```

  The upper bound is the major the module supports, which people choose. The floor is the oldest
  version the module works with; raise it when the module needs something newer.
- **Never pin a provider exactly in a module.** A module's constraint binds every caller: an exact
  pin forces each caller onto that version, and two modules that pin different versions cannot be
  used together.
- **No lock file.** What a caller runs is decided by the caller's own lock file; a lock file in a
  module is ignored by its callers. Without one, every run of the module's CI installs the newest
  release the range allows, which is what a new caller gets.
- **A module the module calls is pinned to an exact version**, `version = "0.4.4"`: a change in a
  called module is a change in what this module ships, so it is made on purpose, by a pull request.

Write each `required_providers` entry with `source` and `version` on lines of their own:
Dependabot does not update an entry written on one line.

## 2. Who moves what

| What changes | Who moves it | How it reaches the default branch | Release |
|---|---|---|---|
| A provider releases within the range | nobody: nothing in the repository changes | every run installs it; the weekly scheduled run tests it | none |
| A called module releases a patch (0.x), or a minor or patch (1.0 and later) | Dependabot | the admission judges it, CI validates and tests it, and it [merges itself](Module-auto-merge.md) | patch, automatically |
| A called module releases a 0.x minor | Dependabot proposes it; a person decides | a person reviews and merges | patch, unless the person says otherwise (§4) |
| A called module releases a new major (1.0 and later) | a person: Dependabot proposes no major | a person's pull request | the version the commits ask for |
| A provider releases a new major | people, as a migration | a person's pull request widens the range or moves it (§4) | minor or major |
| The module needs a newer provider feature | a person | a pull request that raises the floor | minor |
| Anything merged | release-please opens the release pull request | it merges itself when it changes only the changelog and the manifest | the version the commits ask for |

Below 1.0, [semver](https://semver.org) lets any minor break, and many of the modules a module
calls, the Azure Verified Modules among them, are 0.x; a 0.x minor is therefore treated as a major.

## 3. What runs on its own

- **Dependabot** checks every day at 03:00 UTC and proposes a release once it is five days old
  (the cooldown). It updates called modules only, never a provider, and never a major. Its commits
  start with `fix(deps)`, which release-please releases as a patch. The configuration is the same
  in every module repository (§6).
- **The [Dependabot admission](Dependabot-admission.md)** judges each of its pull requests before
  anything runs it: an allowed publisher, at least three days old, and a provider signed as the
  version before it. A refused pull request runs nothing and gets a comment saying why.
- **CI** validates the module and runs every test, credentialed lanes included, and commits the
  regenerated README to the pull request.
- **[Auto-merge](Module-auto-merge.md)** merges an admitted, green Dependabot pull request that
  stays within each dependency's major, and the release pull request that follows. Anything else
  waits for a person, and `Create test matrix` says why in a notice, for example:

  ```text
  auto-merge: not eligible: it moves module Azure/avm-res-network-virtualnetwork/azurerm from 0.17.1 to 0.22.2, past its major (below 1.0, its minor); a person decides that
  ```

- **The weekly scheduled run** tests the module against the newest provider releases in its
  range. A red scheduled run notifies nobody yet: look at the repository's Actions tab.

## 4. When, and what to do

| When | Do |
|---|---|
| A Dependabot pull request waits with `past its major` | Read the called module's release notes for every version it skips, and the pull request's test results. Merge it if it is sound. When it changes what the module's callers get (new or removed inputs, replaced resources), push a commit to the branch whose message says so (`feat:`, or `feat!:` with a `BREAKING CHANGE:` footer), so the release says so too. |
| A Dependabot pull request is refused by the admission | The admission comment says which check failed and what to do. A release that is only too new is admitted when re-run after its age is reached. |
| A Dependabot pull request proposes a provider | It should not happen (§6); auto-merge refuses a provider major. Close it. |
| A called module releases a new major | Read its upgrade notes, change the pin by hand in a pull request, and release as the change to callers warrants. |
| The weekly scheduled run is red | A provider release, or Azure, broke the module or its tests. Fix the module in a pull request (`fix:`). If that takes time, cap the range below the release that breaks it (`>= 4.0.0, < 4.82.0`) as a `fix:` release, and lift the cap with the fix. |
| A provider's next major is released | Nothing happens on its own. When callers are moving, decide per module: **widen** the range (`>= 4.0.0, < 6.0.0`) when the module works with both majors, a `feat:` release; or **move** it (`>= 5.0.0, < 6.0.0`) when the module needs the new major, a `feat!:` release with a `BREAKING CHANGE:` footer. CI tests only the newest release in the range, so after widening, test the older major by hand before the release. |
| The module needs a newer provider feature | Raise the floor in the same pull request as the change that needs it, a `feat:` release; callers update the provider within the major. |
| A release pull request waits | It changes more than `CHANGELOG.md` and the manifest; review and merge it. |

## 5. Why this shape

- **Ranges, not pins, for providers.** HashiCorp's guidance for reusable modules is to constrain
  only the minimum and leave the rest to the root module, which commits a lock
  ([version constraints](https://developer.hashicorp.com/terraform/language/expressions/version-constraints)).
  The upper bound on the major is the Azure Verified Modules' rule
  ([TFNFR26](https://azure.github.io/Azure-Verified-Modules/spec/TFNFR26/)): a provider major may
  break the module, and is tested before a module claims it.
- **No Dependabot for providers.** Within the range there is nothing to update: the newest release
  is already allowed, and every run tests it. What Dependabot proposes for a range is always a new
  major, by rewriting the range, and it did so once despite being told to ignore majors
  (Module-auto-merge.md P10). The configuration updates called modules only, and auto-merge refuses
  a major whatever the configuration says.
- **Exact pins for called modules.** HashiCorp advises exact versions for third-party modules, so
  that their changes arrive when chosen; it says so for root modules, and a module that calls one
  hands its changes to every caller, which is the same concern. Dependabot makes the choosing
  cheap.
- **Every bump its own patch release.** A bumped called module changes what the module ships, so
  it is released; the callers then receive it through their own Dependabot, whose admission and
  plan limits judge it again: a release that changes a caller's plan does not merge there unseen.

The floor is the weak spot: CI installs the newest release in the range, so nothing tests the
floor. Keep it honest: when a floor has not been run for a long time, raise it to what is tested.

## 6. The Dependabot configuration

Every module repository gets the same `.github/dependabot.yml`, maintained centrally:

```yaml
version: 2
updates:
  - package-ecosystem: "terraform"
    directories: ["/"]
    # Called modules only: a registry module's name has three parts (azure/naming/azurerm), a
    # provider's two (hashicorp/azurerm).
    allow:
      - dependency-name: "*/*/*"
    ignore:
      - dependency-name: "*"
        update-types: ["version-update:semver-major"]
    cooldown:
      default-days: 5
    commit-message:
      prefix: "fix(deps)"
    schedule:
      interval: "daily"
      time: "03:00"
    groups:
      dependencies:
        patterns: ["*"]
        group-by: dependency-name
```

It updates the module at the repository root. Versions pinned in `examples/` are not updated;
keep them in step by hand when you touch an example.
