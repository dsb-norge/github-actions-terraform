# Dependabot admission

Authoritative spec for the admission of Dependabot pull requests in
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml) and, when a caller
opts in, [`terraform-module-ci.yaml`](../.github/workflows/terraform-module-ci.yaml): which
Dependabot runs may execute Terraform, decided by the engine from what the pull request changes,
with no person in the loop for a dependency that passes.

Status: **built, and validated on a test bed**: in the project workflow, admitted and refused pull
requests for providers and modules, Dependabot push runs, a module bump needing a new provider, which
`init` refuses as P8 says, and an admitted pull request auto-merged; in the module workflow, admitted
and refused pull requests, the admission head, and the README committed to an admitted pull request,
which Dependabot then rebased (P24). Not yet on a test bed: a re-run after the minimum age. §20
records what implementation and the test bed taught the spec.

**Version holds (§4.6, D23 to D31) are built, and validated on a test bed**: in the project workflow, a
held provider bump refused with its reason, the audit's two warnings on a person's pull request, and
the lifted hold admitting the bump, which then planned and merged itself; in the module workflow, a
held called module refused, rule 8 refusing the merge in the run the docs commit started after the
hold had returned to the base, and the lifted hold merging the bump. The two questions about
Dependabot they raised were answered on the test bed and from public pull requests (§18).

## 1. Why

A Dependabot pull request runs code nobody has looked at. `terraform init` downloads the provider
release or module version the pull request names, and `validate`, `plan` and `terraform test`
execute it: a provider is a program, and a module acts during plan through the data sources of every
provider it uses, provider-defined functions, and `provider` and `import` blocks of its own.
Dependabot opens the pull request automatically, days after an upstream release. Whoever controls
that release controls what runs.

A Dependabot run is often taken for a sandbox, and in part it is. GitHub keeps the repository's,
the organisation's and the environments' Actions secrets from it, and gives it only Dependabot
secrets; its `GITHUB_TOKEN` is read-only unless the workflow's `permissions` say otherwise. (The jobs
in which Dependabot itself computes an update run on GitHub's infrastructure; they are not these
runs.) What GitHub does not restrict is what the caller grants, and what the run's jobs reference.
Observed on a calling repository's Dependabot runs, each log reading `Secret source: Dependabot`,
that code reaches without the admission:

- **The environment's identity.** The environment job runs in its GitHub Environment, so its OIDC
  subject is `repo:<owner>/<repo>:environment:<github-environment>`, the subject an apply on the
  default branch gets; plan and apply usually share one identity per environment. This workflow
  requires its callers to grant `id-token: write`, and GitHub honours it on a Dependabot run: the
  login step printed a token from `https://token.actions.githubusercontent.com` with subject
  `repo:<owner>/<repo>:environment:prod`, logged in to Azure with it, and the plan refreshed real
  state. The caller passed its client ID as a plain value. Client IDs are not secret
  ([Migration-v0-to-v1.md](Migration-v0-to-v1.md) §2.7); the subject is the boundary, and here it is
  the apply identity's.
- **Every Dependabot secret.** A job receives every secret its YAML references, whether or not the
  referencing step runs, and `toJSON(secrets)` references all of them (P2). The environment job's
  export steps and the test job's pass `secrets-json: ${{ toJSON(secrets) }}`: on a Dependabot run
  the environment job's export step received `{"github_token": "***", "<auto-merge key>": "***"}`,
  the auto-merge App's private key, a Dependabot secret because [Auto-merge.md](Auto-merge.md)
  requires it to be. The job then ran `init` and `plan` with the pull request's dependencies.
- **The repository through `GITHUB_TOKEN`**, with what the caller grants. With
  `permissions: write-all` in the caller, the same job's token read `Actions: write`,
  `Contents: write`, `PullRequests: write`.

Two other answers were rejected. Gating the run on a person defeats the point of Dependabot. A
read-only plan identity does not survive contact with the azurerm provider: reading a storage
account, an Event Hub authorisation rule, a container registry with an admin user or a Kubernetes
cluster calls key-returning actions a reader lacks, and the state holds the same secrets anyway.

What a person adds by clicking "plan" on a Dependabot pull request is a policy call: a known
publisher, a release old enough, nothing else in the change. The engine can make that call. After
the merge, an accepted version runs on the default branch with the apply identity whatever happened
on the pull request, so the admission is the decision to accept a version: the same verdict gates
the pull request's credentialed run and, through the conclusion, its auto-merge.

That decision is also where a repository says which versions it does not accept, whoever publishes
them. A provider release can be sound and still wrong for one repository: a project that must stay
on azurerm 3 because a module it calls requires it, while azurerm 3.117 stopped retrying a dropped
connection to Azure Resource Manager, which fails the plan, until 4.12.0 retried again
([go-azure-sdk #1123](https://github.com/hashicorp/go-azure-sdk/pull/1123)). The bump to 3.117 plans
with no changes, passes every plan limit and merges itself overnight. Nothing else in the repository
stops it: Dependabot rewrites the version constraint that would (P30), its `ignore` lives in a
configuration shared by every repository and does not bound the lock (P31), and its comment commands
keep their state out of sight. A **hold** (§4.6) says it where the version is judged.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | An automated admission decides; a dependency that passes needs no person. | Decided by the maintainer. |
| D2 | The admission applies only to runs whose `github.actor` is `dependabot[bot]`; every other run is decided exactly as without it. | GitHub keys its own Dependabot restrictions on the actor. A person's push or dispatch is that person's run. A re-run keeps the actor (§3). |
| D3 | **Admitted**: the run is decided as a person's run would be. Environment rows run in their GitHub Environment with their identity, and every test row runs, credentialed lanes included (D20). | Plan what will be applied: the plan is a person's plan, with the same lock and the same concurrency group. |
| D4 | **Not admitted**: no environment row and no test row runs, so no job of the run executes Terraform; the conclusion is red with the reason. | A job holds every secret the run can see (P2); running nothing is what keeps them from code that failed. Red is the maintainer's decision: green would let a merge apply, on the default branch, a version nobody saw planned. |
| D5 | The rule judges content only: the change from the merge commit's first parent to the merge commit (`github.sha`), the commit the run checks out. Commit authorship is not consulted. | The actor already says who pushed, and a content rule covers every commit whoever wrote it (P3). |
| D6 | One allow list of namespaces, for providers and modules alike. An entry is a namespace (`elastic`) or a namespace and name (`cyrilgdn/postgresql`), compared without case. Built in: `dsb-norge`, `hashicorp`, `microsoft`, `Azure`. A caller's entries are added to the built-in ones. | Decided by the maintainer: the publishers the organisation trusts. Adding rather than replacing, so nobody drops `hashicorp` by mistake. |
| D7 | A changed provider or module version must have been published at least `min-age-days` before the run (default 3). Namespaces in `min-age-exempt` (built in: `dsb-norge`) are exempt. | Decided by the maintainer. 3 matches Dependabot's default cooldown, so a repository on the default or a longer cooldown never trips it; the check catches a cooldown lowered or removed. The organisation's own modules gain nothing from waiting. |
| D8 | A changed provider's new version must be signed with a key that signed the base version, or with a key HashiCorp vouches for: HashiCorp's own, or one whose partner trust signature verifies against HashiCorp's partner key, as Terraform checks it. Every `zh:` hash its lock entry records must be in the publisher's checksum file for that version. | A publisher's key changing to one nobody vouches for is what a takeover looks like, and it happens: a partner provider's version that Terraform installs as "signed by a HashiCorp partner" was followed by one it installs as "self-signed" (P10). A rotation HashiCorp has vetted passes, decided by the maintainer. The hashes tie the lock to what the registry signed. |
| D9 | Module content is not inspected. | No scan of HCL text is sound (unquoted block labels, JSON syntax, escapes), plan-time code takes many forms (data sources of every provider, provider functions, child `provider` and `import` blocks, `file()`), and legitimate upgrades add providers and examples. The boundary is the identity, the allow list and the provenance checks; a scan would slow an attacker, not stop one (§12). |
| D10 | On a Dependabot run, the environment root's `init` uses `-lockfile=readonly`, and every environment the change is relevant to must have a committed lock file. | Terraform then refuses a provider the lock does not record before anything executes it: `init` downloads and verifies it but fails with "Provider dependency changes detected", and `validate` and `plan` then refuse without starting a provider (P8). A constraint change the locked version still satisfies passes. |
| D11 | A fact the admission needs that cannot be gathered (a registry or GitHub API error, an answer of an unexpected shape) fails the `create-matrix` job, naming the fact. | Decided by the maintainer. "Re-run failed jobs" then decides again; a red conclusion alone would keep the decided verdict on that kind of re-run. Only Dependabot runs gather these facts. |
| D12 | Content the admission cannot interpret (a file it cannot parse, a source kind it does not know) fails a check; it is not a failed fact. | It would not parse on a re-run either. |
| D13 | Two inputs: `dependabot-admission-enabled` (boolean) and `dependabot-admission-yml` (the policy). The switch defaults to `true` in the project workflow and to `false` in the module workflow. | Decided by the maintainer: the repository's convention for switches. On by default for projects, so a repository that forgets it is still caught by the default policy; opt-in for modules, whose Dependabot runs reach no cloud identity (§11). |
| D14 | With `dependabot-admission-enabled: false` every run is decided exactly as before the admission existed. | The opt-out that keeps this a minor release (§13). |
| D15 | The report lists every changed dependency with its result, once, in an admission head (one per calling workflow) and in the run summary. Each environment and group head says "not admitted" and points to it. Each failed check carries what to do when the change is trusted and intended. | Decided by the maintainer. |
| D16 | In the module workflow, when enabled, the admission gates `validate` and the tests. | Decided by the maintainer: both execute the new provider. |
| D17 | A Dependabot `push` run (from a caller that triggers on every branch) runs nothing and is green, with a notice. | Its checks land on the pull request's head commit, and a required check needs every check run of that name on the commit to pass, whatever order they finish in (P5): a red push run would block an admitted pull request, and a green one cannot unblock a refused one. The pull request's own run judges the change. |
| D18 | Azure IDs are plain values in the caller (`extra-envs-yml`, per environment), not secrets. | Decided by the maintainer. A Dependabot run cannot read Actions or environment secrets, and Dependabot secrets have no environment level, so a repository with several environments could not give each its own ID. The IDs protect nothing (§1). |
| D19 | `allow-failing-terraform-operations` never softens a not-admitted run. | Nothing ran; the setting is about operations that did. |
| D20 | On an admitted Dependabot run, the test stage drops no lane for `secrets unavailable`: a credentialed lane runs as on a person's run. Its credentials reach a Dependabot run only as plain values in the lane's `extra-envs-yml` (the IDs, with OIDC through the lane's GitHub Environment) or as Dependabot secrets; a lane that keeps them as environment secrets fails there. No setting selects the lanes, and nothing detects which lanes would succeed. Fork runs and runs with the admission off keep today's rule. | Decided by the maintainer: callers move the lane IDs to plain values, as D18 does for environments, and a lane that has not moved fails visibly rather than being skipped. A behaviour change for callers on v1 with credentialed lanes, accepted while few callers are on v1 (§13). |
| D21 | The module workflow posts the admission head too: the engine's module output carries it, and a copy of the project workflow's seed job posts it on a refused run and purges it on a later run of the pull request that is not refused. The copy runs on pull requests Dependabot opened only. | Found on the test bed: a refused module pull request showed no comment at all, while its conclusion said "see the admission comment". |
| D22 | On a Dependabot pull request, the module workflow's docs job commits the regenerated README when `create-matrix` judged and admitted the run (`admission-admitted`), and in no other run on that pull request, whoever started it (P26). It commits only on top of the commit the run evaluated (P23), with `[dependabot skip]` in the message so Dependabot keeps rebasing (P24), using the organisation App, whose key must then also be an organisation Dependabot secret. The run the commit starts is the App's: it is not judged, as a person's push is not, and it reads the repository's Actions secrets (R7); with the module workflow's auto-merge on, that run also merges the pull request ([Module-auto-merge.md](Module-auto-merge.md) M2). | Decided by the maintainer: module repositories move to Dependabot, and the template's README lists the providers' constraints and the modules' versions, so nearly every bump made the README stale and the docs check red (P25). Without the admission, or on a refused run, a commit would hand a change nobody judged to a run that reads every secret, so the README is checked as before. |
| D23 | A repository can **hold** a dependency: refuse every Dependabot pull request that moves it into a range of versions, with a reason. A held pull request is not admitted (D4): nothing runs, the conclusion is red, auto-merge does not run, and the admission head gives the hold and its reason. | Decided by the maintainer. What hurts is not the proposal but its merge: a bump whose plan shows no changes passes every plan limit and merges unseen. A constraint in the code does not hold (P30); Dependabot's `ignore` is in the shared configuration and does not bound the lock (P31); its comment commands keep their state out of the repository. The admission already judges the version that runs, the lock's (P16), and its verdict already stops auto-merge. |
| D24 | Holds are declared under `hold` in `dependabot-admission-yml`, per calling workflow. | Decided by the maintainer: the admission's policy in one place and validated with it; a hold reaches the default branch through a pull request, like any other change to the caller. A repository with several calling workflows declares it in each that judges the pull request (P42). |
| D25 | A hold names its dependency with an explicit kind, `provider` or `module`: a provider as a `required_providers` source or a lock file writes it, a module as its package, a registry source or a GitHub repository without subdirectory or ref; `versions` is **one** Terraform constraint, the versions the hold keeps out; `reason` is required. | Decided by the maintainer. An explicit kind turns a malformed name into a validation error: read from the number of parts, `Azure/naming` (the allow list's form) would be a provider hold that matches nothing. The polarity is that of Dependabot's `ignore`, Gradle's `reject`, Maven's `bannedDependencies` and cargo-deny's `deny`: the versions refused, not the ones kept. One string, not a list: a list read as "any of" turns `[">= 3.117.0", "< 4.0.0"]` into a hold on every version; two ranges are two holds. |
| D26 | A hold is matched against the version the admission judges (§4.2 to §4.4), with two departures from Terraform's reading, both towards holding: a pre-release is held when either its place in version order or its release is in the range (`4.0.0-beta1` by `>= 4.0.0`, `4.12.0-rc1` by `< 4.12.0`), and a version that cannot be read is held. | Terraform's ranges never select a pre-release, so read as Terraform reads it, every range would let every pre-release through (P32); a moving tag such as `v3` may point at a held 3.x (P33). A hold that guesses fails open. |
| D27 | When holds are set and the admission is on, every run **audits** them against the repository and warns about a hold that matches nothing the repository uses, and about a committed lock or exact module version that a hold covers. Warnings, never errors. | Decided by the maintainer. A misspelt hold fails open, an inverted one (`versions: "3.116.0"`, meant as "keep 3.116.0") holds the version the repository runs (P35), and a hold added after the version arrived leaves it running. Warnings, because an error on every event would stop the default branch's applies on a false positive. |
| D28 | A hold carries no date. | Decided by the maintainer. The reason says when to lift it, and the refused pull request, left open, is the reminder (D31). The security scanners' expiry (OSV-Scanner, Snyk, Trivy) lapses, which for a hold fails open: on the day after, the held bump is admitted and may merge unseen. |
| D29 | `hold` with `dependabot-admission-enabled: false` is a validation error. | The hold would be validated and never applied, silently; the module workflow's admission is off by default (D13). |
| D30 | Module auto-merge refuses a Dependabot pull request that a hold covers, in the run its docs commit starts too ([Module-auto-merge.md](Module-auto-merge.md) rule 8). | The admission does not judge that run (D22, R7). A hold that lands between Dependabot's admitted run and the docs commit is on the base the App's run merges against, and only the rule sees it (P43). |
| D31 | A held pull request is left open; nothing closes it. | The open, red pull request is the reminder that the hold exists. Closing it makes Dependabot skip that version even after the hold is lifted (P40); the help says so. |

## 3. Who meets the admission

| Run | Admission |
|---|---|
| `pull_request` with actor `dependabot[bot]`: opened, reopened, or synchronized by a rebase or a recreate | judged |
| a re-run of such a run, whoever starts it | judged again: GitHub re-runs keep `github.actor` and the event, so the same merge commit is judged, with the facts gathered anew when `create-matrix` itself re-runs |
| `push` with actor `dependabot[bot]` to its branch | runs nothing, green, with a notice (D17) |
| a run whose actor is a person: a commit pushed to the Dependabot branch, a dispatch | not judged; the person's run |
| any run when `dependabot-admission-enabled` is `false` | not judged |

The pull request's author (`pull_request.user.login`) is not consulted: it stays `dependabot[bot]`
after a person pushes. `github.triggering_actor` is not consulted either: on a re-run it is the
person, while the run keeps Dependabot's privileges.

## 4. The rule

A Dependabot pull request is admitted when every check of §4.1 to §4.6 passes. The checks judge the
change from the merge commit's first parent to the merge commit, read through git in the
`create-matrix` checkout (D5): that is exactly the tree every job of the run checks out.

### 4.1 The shape of the change

Every changed file is one Dependabot's Terraform updater writes, and every change is one it makes:

- **`*.tf`**: each changed line replaces exactly one line, and the two differ only inside the
  quoted value of a `version` argument (of a `required_providers` entry or of a `module` block) or
  inside the `ref` value of a GitHub module source. No line is added or removed. A constraint the
  updater rewrote (a range whose `!=` terms it dropped) passes: the difference is inside the value.
  A line that changes only inside a version but belongs to no `module` block or `required_providers`
  entry, a legacy `provider` block's `version` for one, is refused: the change it makes is one nothing
  judges (P20).
- **`.terraform.lock.hcl`**: parsed, before and after hold the same provider addresses; a block
  that changed changed its `version`, and may change its `constraints` and `hashes`; every other
  block is unchanged. Whitespace and comments are not compared: the updater regenerates a block
  with `terraform providers lock`, which re-pads `version` lines
  ([Terraform-tests.md](Terraform-tests.md) P46).
- **Nothing else**: no other kind of file, no added, deleted or renamed file, no mode change.
  `*.tf.json` and any other `*.hcl` fail: the updater never writes the first, and the second is
  Terragrunt's.

A pull request whose only change is a lock file (a version the existing constraint already allows)
passes this check.

The rule was run over 119 real Terraform Dependabot pull requests of a calling organisation: 41
lock-only, 52 `.tf`-only, 26 both, 30 of them across several directories. Every change Dependabot
made itself passed. The two refusals were pull requests that something else had pushed to: a person's
commit changing a lock's `constraints` line, and a documentation bot's README commit.

### 4.2 The dependencies

From the shape, the dependencies the pull request changes:

- a **provider**: each lock block whose version changed (`registry.terraform.io/<namespace>/<type>`),
  and each `required_providers` entry whose `version` changed in a directory without a lock file;
- a **module**: each `module` block whose `version` changed (a registry source
  `<namespace>/<name>/<provider>`) or whose GitHub source's `ref` changed
  (`github.com/<owner>/<repo>` or `git::https://github.com/<owner>/<repo>.git`). Either kind may
  name a module inside the package with `//<subdirectory>`; the subdirectory comes with the
  package's version, so the package is what is judged.

A grouped pull request changes several dependencies in several directories. Each distinct
dependency, old version and new version is checked once, and the report lists every file it appears
in.

### 4.3 Providers

| Check | Passes when | Fact (§8) |
|---|---|---|
| `host` | the address is on `registry.terraform.io` | the address |
| `hold` | no hold of the repository covers the new version, or names the dependency and cannot read it (§4.6); listed only when the policy sets `hold` | the policy and the new version |
| `allow` | its namespace, or namespace and type, is on the allow list | the address |
| `age` | the new version was published at least `min-age-days` before the run, or the namespace is exempt | the version's publication time |
| `key` | the new version's signing key IDs share one with the base version's, or a new key is HashiCorp's own or carries a partner trust signature that verifies against HashiCorp's partner key | each version's signing keys and their trust signatures |
| `hashes` | every `zh:` hash in the new lock block is in the publisher's checksum file for the version | the checksum file |

For a `required_providers` change in a directory without a lock file, "the new version" is the
newest version the new constraint allows, which is what `init` installs there; `key` compares it with
the newest version the old constraint allows, and `hashes` does not apply. Constraints are read as
Terraform reads them (`=`, `!=`, `>`, `>=`, `<`, `<=`, `~>`, comma-separated; a pre-release only by
an exact `=`).

### 4.4 Modules

| Check | Passes when | Fact (§8) |
|---|---|---|
| `source` | a registry module on `registry.terraform.io`, or a GitHub source; any other source kind fails (D12) | the source |
| `hold` | no hold of the repository covers the new version, or names the dependency and cannot read it (§4.6); listed only when the policy sets `hold` | the policy and the new version |
| `allow` | the registry namespace or GitHub owner, or namespace and name, owner and repository, is on the allow list | the source |
| `age` | the new version was published at least `min-age-days` before the run, or the namespace is exempt | registry: the version's publication time; GitHub: the publication time of the tag's release |

A GitHub source's age is the `published_at` of the release made from its tag, which GitHub sets when
the release is published. Commit and tag dates are not used: the client sets them (P9). A tag with
no release fails `age` unless the owner is exempt.

### 4.5 Locks

Every environment the change is relevant to has a committed `.terraform.lock.hcl` in its project
directory. With D10, the lock is then the complete list of what that environment's `init` may install.

### 4.6 Holds

A hold keeps Dependabot from moving one dependency into a range of versions, and says why (D23). It
is declared in `dependabot-admission-yml` (§6):

```yaml
        hold:
          - provider: hashicorp/azurerm
            versions: "> 3.116.0, < 4.12.0"   # the versions Dependabot may not bring in
            reason: >-
              azurerm 3.117 stopped retrying a dropped connection to Azure Resource Manager, which
              fails the plan; 4.12.0 retries again. Lift when the landing-zone module allows azurerm 4.
```

**What a hold names.** Exactly one of two keys; names compare without case:

| Key | Names | Matches |
|---|---|---|
| `provider` | `<namespace>/<type>`, or `registry.terraform.io/<namespace>/<type>` as a lock file writes it | the provider with that address, in a lock file or a `required_providers` entry |
| `module` | `<namespace>/<name>/<provider>`, with or without `registry.terraform.io/` | the registry module, called directly or through a `//<subdirectory>` of it: the package is held |
| `module` | `github.com/<owner>/<repo>`, or the same repository as `git::https://github.com/<owner>/<repo>.git`, `git::ssh://git@github.com/<owner>/<repo>.git` or `git@github.com:<owner>/<repo>.git` | every GitHub source of that repository, whatever its form, subdirectory or ref |

A hold names the package, never a subdirectory or a ref; any other source kind is a validation
error, since the admission refuses every other kind anyway (`host`, `source`).

**Which versions it holds.** `versions` is one Terraform version constraint: conditions separated by
commas, each `=`, `!=`, `>`, `>=`, `<`, `<=` or `~>` followed by a version written without `v`; a
bare version is `=`. A version is held when it satisfies every condition, read as Terraform reads
them, so `~> 3.117` holds every 3.x from 3.117.0 on.

The version judged is the new version the other checks judge: a locked provider's version in the
lock; in a directory without a lock, the newest version the new constraint allows (§4.3); a registry
module's exact version, or the newest its constraint allows; a GitHub module's new ref, read as
`<major>.<minor>.<patch>` with an optional `v` and an optional pre-release. Two departures from
Terraform's reading, both towards holding (D26):

- **A pre-release is held when its place in version order or its release is in the range.**
  `4.0.0-beta1` is held by `>= 4.0.0` through its release, `4.12.0-rc1` by `< 4.12.0` through its
  order; Terraform's ranges never select a pre-release at all (P32). A hold's own conditions name
  releases only.
- **A version that cannot be read is held.** A GitHub ref that is not `<major>.<minor>.<patch>`
  (`v3`, a moving tag that may point at a held version (P33); `release-1.2.3`; a branch) cannot be
  compared, and a module a hold names fails `hold` with such a ref.

Several holds may name one dependency. It is held when any of them covers its version, and the report
gives every hold that does. A dependency no hold names passes `hold`. A policy without holds lists no
`hold` check, so nothing in the output changes (I30).

**What a hold does not do.**

- It judges Dependabot's pull requests, nothing else (§3). A person who runs `terraform init
  -upgrade`, opens a pull request or pushes to Dependabot's branch is not held; the audit warns when a
  held version reaches a committed lock or module pin.
- It does not change what `init` installs. In a project's environments the lock decides (D10); where
  nothing locks a version, in a module repository or a directory without a lock, `init` installs the
  newest version the constraint allows, held or not, and the constraint is what keeps a version out
  there (R8; [Module-dependencies.md](Module-dependencies.md) §4).
- It holds the dependency it names. A module bump whose new version requires a held provider version
  is not held: under D10 its `init` fails (P8), and the fix is not to move the lock into the hold
  (P44).
- It refuses the whole pull request, as every check does. Where Dependabot's groups use
  `group-by: dependency-name`, each dependency has a pull request of its own, so a hold refuses only
  that dependency's.
- It does not stop Dependabot from opening the pull request, which stays open and red (D31, §12).

**The audit (D27).** When `hold` is set, which needs the admission on (D29), every run, whatever its
event, lists the dependencies the repository uses in its committed files (§8) and warns:

- about a hold that matches nothing: no committed lock file records the provider and no
  `required_providers` entry names it, or no `module` block's source names the module. A misspelt
  hold, or one left behind when the dependency went, holds nothing;
- about a committed lock that records a held version, or a `module` block whose exact version, or
  GitHub ref read as `<major>.<minor>.<patch>`, is held. The repository already runs what the hold
  keeps out: the hold was added after the version arrived and the pin is missing, the range is
  inverted (P35), or a person moved into it. A ref it cannot read is not warned about; a move to one
  is refused all the same (D26).

On a run the admission judges, the audit leaves out the dependencies the pull request changes: their
held versions are in the merge commit because the pull request brings them, and the admission's
verdict says so. The run a module's docs commit starts is not judged, so there the audit warns about
a held version the pull request brings in, beside rule 8's notice (D30). The warnings are the engine's,
`::warning` annotations of the `create-matrix` job like its other warnings, and never change a
verdict. `hold:` left empty, or `hold: []`, sets no hold:
no audit, and no error with the admission off.

**When a hold takes effect.** A pull request's run reads the calling workflow from the pull request's
merge commit, and a re-run keeps that commit
([GitHub](https://docs.github.com/en/actions/how-tos/manage-workflow-runs/re-run-workflows-and-jobs)).
A hold on the default branch therefore applies to each Dependabot pull request's next new run, a
rebase, a recreate or a newer version, and **never to a re-run** of a run made before it (P37). The
hold and the pin can land in one pull request: from then on, every new Dependabot run of that
dependency is judged with the hold. After adding or lifting a hold, comment `@dependabot rebase` on
the dependency's open pull requests.

### 4.7 Facts that cannot be gathered

When a fact of §8 cannot be gathered, `create-matrix` fails with an error annotation naming the fact
and the dependency, and no verdict is published (D11). The engine's adapter otherwise turns every
failure into a fact and exits 0 ([Decision-engine.md](Decision-engine.md) §3.1); this is a deliberate
exception, confined to Dependabot runs, because an admission that guesses either way is wrong:
admitting runs unjudged code, refusing sends a person to look at nothing.

## 5. What a verdict does

### 5.1 Admitted

The decision is the one the same document would produce without the admission (D3), and the
environment root's `init` runs with `-lockfile=readonly` (D10). Every test row runs, credentialed
lanes included (D20); a lane whose credentials are environment secrets fails its credential check,
which on a Dependabot run says that environment secrets do not reach it and names the plain-value
alternative (P19). Auto-merge evaluates the run as any other
([user guide, example 13](Workflow-terraform-ci-default.md#13-auto-merge-for-dependabot)).

### 5.2 Not admitted

- Every environment that passed rules 2 and 3 is dropped with the reason `admission: not admitted`.
  Relevance is still computed for each, so the report and the auto-merge evidence show which
  environments the change touches.
- Every test file is listed as not run with the same reason; in module mode a required test stage
  therefore does not read as missing.
- `create-matrix` publishes `admission-refused: true`. The conclusion's run block fails on it before
  any other branch, `allow-failing-terraform-operations` notwithstanding (D19), with the line
  `Dependabot pull request not admitted: <n> of <m> dependencies failed; see the admission comment.`
- The admission head is posted (§7). A red conclusion keeps auto-merge from running.

### 5.3 Dependabot push runs

Every environment is dropped with the reason `admission: Dependabot push run`, every test file is
listed as not run with the same reason, and the run carries
the notice `admission: a Dependabot push run runs nothing; its pull request's run judges the change`.
The conclusion is green ("nothing to verify for this change"), as for any run with no affected
environment (D17).

## 6. Configuration

```yaml
      dependabot-admission-enabled: true   # default in the project workflow; false in the module workflow
      dependabot-admission-yml: |
        allow:                             # added to: dsb-norge, hashicorp, microsoft, Azure
          - elastic
          - integrations/github
          - cyrilgdn/postgresql
          - cloudposse/label/null
        min-age-days: 3                    # default
        min-age-exempt:                    # added to: dsb-norge
          - my-other-org
        hold:                              # none by default
          - provider: hashicorp/azurerm
            versions: "> 3.116.0, < 4.12.0"   # the versions Dependabot may not bring in
            reason: >-
              azurerm 3.117 stopped retrying a dropped connection to Azure Resource Manager, which
              fails the plan; 4.12.0 retries again. Lift when the landing-zone module allows azurerm 4.
          - module: my-other-org/network/azurerm
            versions: ">= 2.0.0"
            reason: 2.0.0 replaces the subnets the environments use; we move by hand.
```

- Both inputs are workflow-wide: an environment may not set them. `dependabot-admission-yml` joins
  the `*-yml` inputs that are parsed and never forwarded into a row, so no row changes.
- `dependabot-admission-yml` is empty (the defaults) or a mapping with the keys `allow`, `hold`,
  `min-age-days` and `min-age-exempt`.
- `allow` and `min-age-exempt` are lists of strings, a single string being one item. Each entry is
  `<namespace>` or `<namespace>/<name>`, each part matching `^[A-Za-z0-9][A-Za-z0-9_.-]*$`.
- `min-age-days` is an integer from 0 to 90.
- `hold` is a list of holds (§4.6). Each is a mapping with exactly one of `provider` and `module`,
  and `versions` and `reason`, and no other key:
  - `provider` is `<namespace>/<type>`, optionally prefixed with `registry.terraform.io/`;
  - `module` is `<namespace>/<name>/<provider>`, optionally prefixed with `registry.terraform.io/`, or
    a GitHub repository in one of the forms of §4.6, without a subdirectory or a ref; each part
    matches `^[A-Za-z0-9][A-Za-z0-9_.-]*$`;
  - `versions` is a string: a Terraform version constraint of releases, without `v`, that at least
    one release satisfies. A YAML number is refused rather than read (`3.10` would be `3.1`): quote it;
  - `reason` is a string that is not blank.
- A non-empty `hold` needs `dependabot-admission-enabled: true` (D29); `hold:` left empty and
  `hold: []` set no hold.
- The settings are validated on every event, whether or not the run is a Dependabot run, so a mistake
  shows on the pull request that makes it. The audit's warnings (D27) are not validation: they
  report the repository, not the settings.

Every message, in the order they are reported, is in
[Configuration-validation.md](Configuration-validation.md) §3.9. An environment setting either input
gets the existing message for a workflow-only input.

## 7. Reporting

**The admission head**, marker `<!-- tf:head:admission:<caller> -->`, one per calling workflow
like the tests head ([Workflow-pr-comments.md](Workflow-pr-comments.md) §2). The engine's comment
manifest carries it, the seed job posts it with its final body (no matrix job runs to finalise it),
and the seed deletes it on any later run of a Dependabot-authored pull request that is not refused: an
admitted run, a person's push, a run with the admission switched off. The pull request's author
(`event.pull_request.author`) is what says whose pull request it is.

```markdown
### 🚫 Dependabot pull request not admitted

No Terraform ran. Every dependency a Dependabot pull request changes must pass the admission
before any job runs it ([what the admission checks](<link to this spec>)).

| Dependency | Change | Result |
|---|---|---|
| provider `hashicorp/azurerm` | 4.41.0 → 4.42.0 | ✅ admitted |
| provider `cyrilgdn/postgresql` | 1.25.0 → 1.26.0 | ❌ `cyrilgdn` is not on the allow list |
| module `Azure/naming/azurerm` | 0.4.3 → 0.4.4 | ❌ published 1 day ago; the minimum is 3 days, reached at 2026-09-23 14:13 UTC |

<details><summary>Files</summary>

- `envs/dev/.terraform.lock.hcl`, `envs/prod/.terraform.lock.hcl`: provider `hashicorp/azurerm`
- `envs/prod/.terraform.lock.hcl`: provider `cyrilgdn/postgresql`
- `main/naming.tf`: module `Azure/naming/azurerm`

</details>

**If you trust provider `cyrilgdn/postgresql` and the update is intended:** add `cyrilgdn/postgresql`
(or `cyrilgdn`) to `allow` in `dependabot-admission-yml` in the calling workflow on the default
branch, then comment `@dependabot rebase` on this pull request.

**module `Azure/naming/azurerm` 0.4.4 is too new:** published 1 day ago; the minimum is 3 days,
reached at 2026-09-23 14:13 UTC. Then re-run all jobs of this run.

**To run this pull request once without changing the policy:** push a commit to its branch. That run
is yours and is not judged; Dependabot stops rebasing the pull request.
```

A held pull request (§4.6):

```markdown
### 🚫 Dependabot pull request not admitted

No Terraform ran. Every dependency a Dependabot pull request changes must pass the admission
before any job runs it ([what the admission checks](<link to this spec>)).

| Dependency | Change | Result |
|---|---|---|
| provider `hashicorp/azurerm` | 3.116.0 → 3.117.1 | ❌ held by this repository: `> 3.116.0, < 4.12.0` |

<details><summary>Files</summary>

- `envs/dev/.terraform.lock.hcl`, `envs/prod/.terraform.lock.hcl`: provider `hashicorp/azurerm`

</details>

**provider `hashicorp/azurerm` 3.117.1 is held by this repository.** Reason: azurerm 3.117 stopped
retrying a dropped connection to Azure Resource Manager, which fails the plan; 4.12.0 retries again.
Lift when the landing-zone module allows azurerm 4. When that no longer applies, remove or narrow the
hold on `hashicorp/azurerm` in `dependabot-admission-yml` in the calling workflow on the default
branch, then comment `@dependabot rebase` on this pull request. Until then leave this pull request
open: closing it makes Dependabot skip 3.117.1 even after the hold is lifted. It counts towards
Dependabot's limit of open pull requests (5 by default).
```

The last paragraph of the first example is left out when every failed check is `hold`: a hold is
the repository's decision against that version, and the paragraph would invite running it anyway
(P36). The reason is shown as written, its whitespace collapsed and `<` escaped (P41).

What each failed check tells the reader:

| Check | Help |
|---|---|
| `hold` | in the table, the range of every hold that covers the version, joined by "and", a `~>` with its reading (`~> 3.117` (`>= 3.117.0, < 4.0.0`)), or that the version cannot be compared (`` `v3` is not a version a hold can compare ``); below it, the hold's reason (with several, `Reason for <range>:` each), how to lift it, and why to leave the pull request open (D31) |
| `allow` | add the namespace, or namespace and name, to `allow` on the default branch, then `@dependabot rebase` |
| `age` | the date and time it becomes old enough; then "Re-run all jobs", since the verdict is decided in `create-matrix` |
| `key` | the old and new key IDs and how Terraform authenticates each ("signed by a HashiCorp partner", "self-signed"); a new key HashiCorp does not vouch for, a self-signed one, is lock-file maintenance for a maintainer: verify the key with the publisher, then update the lock by hand in a commit of their own |
| `hashes` | the lock records a hash the publisher did not publish: do not merge; comment `@dependabot recreate` |
| `host`, `source` | the admission judges registry and GitHub sources only; a person's commit runs it |
| the shape | the file and line that is not a dependency version; review it; a person's commit runs it |
| the lock | the environment and its project directory; commit a lock file on the default branch, then `@dependabot rebase` |

**Environment and group heads** of a refused run: an environment's head gets a final body from the
seed, `🚫 Not admitted: this Dependabot pull request failed the admission, so nothing ran (run #N attempt #M). See the admission comment.`;
a group head shows a member with a `🚫` cell and names it in a `🚫 Not admitted:` footer line.

**The run summary** gains an admission section before the environments: the table above, without
the help. **The conclusion** fails with the line of §5.2.

**The module workflow** posts the same admission head, through its own copy of the seed job (D21):
the engine's module output carries the head and its purge as the project manifest does, and the
module workflow has no environment or group heads to add.

## 8. Facts and where they come from

The `create-matrix` adapter gathers these only when the admission applies (§3), in the run a docs
commit starts on Dependabot's pull request for module auto-merge's rules 7 and 8, and, for the audit's
inventory, on every event when holds are set. It hands the core parsed inventories, never file
contents; the log of the input document leaves them out, as it leaves out `changed_files`.

| Fact | Source | On failure |
|---|---|---|
| the change | `git diff --raw -z -M HEAD^1 HEAD` (statuses, renames, mode changes) and `git show <rev>:<path>`, in the `create-matrix` checkout (fetch depth 2); a `.tf` file's changed lines are paired, a lock file is parsed before and after | `create-matrix` fails |
| where a changed line belongs | a scan of the `.tf` file that skips strings, comments and heredocs and maps each `version` or `source` argument to its `module` block or `required_providers` entry, written on several lines or on one | — |
| a module's package | its source classified: a registry module's namespace, name and provider; a GitHub repository's owner and name, `.git` dropped without case; never the subdirectory or the ref. A hold matches it (§4.6) | — |
| the directories with a committed lock | `git ls-files` | `create-matrix` fails |
| the time of the run | the adapter's clock, in UTC, once per run (the core reads no clock) | — |
| a provider version's publication time | `GET https://registry.terraform.io/v1/providers/<ns>/<type>/<version>` → `published_at` | `create-matrix` fails |
| a provider version's signing keys and checksum file | `GET …/v1/providers/<ns>/<type>/<version>/download/linux/amd64` → `signing_keys.gpg_public_keys[]` (`key_id`, `ascii_armor`, `trust_signature`), `shasums_url`; then the file at `shasums_url` | `create-matrix` fails |
| whether HashiCorp vouches for a new key | the key ID against HashiCorp's own; otherwise the `trust_signature`, a detached signature over the key's de-armoured bytes, verified with `gpg` in a temporary keyring holding HashiCorp's partner key (a constant in the adapter, taken from Terraform's source) (P18) | `gpg` missing or erroring: `create-matrix` fails; a signature that does not verify is the fact "not vouched" |
| a provider's versions (constraints without a lock) | `GET …/v1/providers/<ns>/<type>/versions` | `create-matrix` fails |
| a registry module version's publication time | `GET https://registry.terraform.io/v1/modules/<ns>/<name>/<provider>/<version>` → `published_at` | `create-matrix` fails |
| a GitHub module tag's release | `gh api repos/<owner>/<repo>/releases/tags/<tag>` → `published_at`; a 404 is the fact "no release" | other errors: `create-matrix` fails |
| the environments' committed locks | the merge commit, as the test stage already reads them | — |
| the repository's dependencies, for the audit (D27) | on **every event** when the parsed policy sets `hold`: `git ls-files -z -- '*.tf' '*.terraform.lock.hcl'` in the checkout, each lock's provider addresses and versions, each `required_providers` entry's source, and each `module` block's source and `version` (a GitHub source's ref), with the file they are in, read with the scans that read the change. Local reads only, no API call (P12) | a file that cannot be read or parsed is left out, and a warning names it; a listing that fails is the fact `available: false`, and one warning says the holds were not audited; never fails the step |

The registry calls must not depend on IPv6 (P17): the adapter calls the registry through `curl`, which
tries IPv4 and IPv6 side by side, with a timeout and one retry. Measured: the calls for a grouped pull
request of a dozen providers take about five seconds in sequence, and 108 calls twenty at a time
met no rate limit and carried no rate-limit headers. Only the registry's
download and versions endpoints are documented; the version detail endpoints are not, so every answer
is checked for the fields read, and a missing or mistyped field is a failed fact (D11).

## 9. The engine

- **Input document**: a new optional key, `admission`, present only for a Dependabot pull request
  the admission applies to: the time of the run, the changed files (a `.tf` file's changed lines, a
  lock file parsed), the dependencies with their facts, and the directories with a committed lock.
  The policy is read from the inputs, as every other setting. `event.pull_request.author` is new too.
  A module dependency carries its package (§8), `provider` included. A second optional key,
  `dependency_inventory`, is the audit's inventory (§8), present on every event when the parsed
  policy sets `hold`; it is kept apart from `admission` so that I28 holds as written.
  `model.check` validates their shape; `schema_version` stays 1, as for the earlier optional keys.
- **Core**: a new module, `admission.py`, pure like the rest of the core: the checks of §4 over the
  facts, giving the `admission` block of the output:
  `{"applies", "admitted", "push_run", "dependencies": [{"kind", "address", "from", "to", "files",
  "checks": [{"check", "ok", "detail"}]}], "refused_count", "total"}`. For holds it also reads
  `hold` in `settings()`, with a reader of hold ranges that reads every condition and refuses what §6
  refuses (`allows()` stops at the first condition a version fails, so a later unreadable one goes
  unseen, and it allows every release for an empty constraint, P34); the `hold` check; and the audit,
  whose warnings join `warnings`.
- **Placement**: a rule between rules 3 and 4 of [Decision-engine.md](Decision-engine.md) §6,
  numbered 3a so the numbers other specs cite stay valid. It drops environments through the same
  path as rules 2 and 3, so rule 4 still computes relevance for each; the lock check of §4.5 reads
  that relevance.
- **Output**: `admission` in the output document, in the published `relevance.json` for the seed,
  the aggregator, the run summary and the auto-merge evaluator, and a step output
  `admission-refused`, in both modes.
- **Vocabulary**: the reasons `admission: not admitted` and `admission: Dependabot push run`; the
  head state `not-admitted`; the admission head.
- **Invariants** (as built in [Decision-engine.md](Decision-engine.md) §7): I4 reads "When secrets are unavailable (a fork, or Dependabot with the admission
  not applying)"; I6 and I13 read "passed rules 2, 3, 3a and 5"; I11 gains the two reasons; I14
  gains the `not-admitted` head and the admission head. New:
  - **I26**: the admission block's `applies` is true only when the actor is `dependabot[bot]`, the
    switch is on and the event is `pull_request` or `push`.
  - **I27**: when the admission refuses, no environment has verdict `run` and no test row exists.
  - **I28**: when the admission does not apply, the output equals the output of the same document
    without the `admission` key.
  - **I29**: when the admission admits, every environment's verdict and row equal those of the same
    document without the `admission` key.
  - **I30**: when the admission applies to a pull request and a hold covers a dependency's new
    version, or names it and cannot read that version, the dependency's `hold` check fails and the
    pull request is not admitted; without `hold`, no dependency lists a `hold` check.

  I28 does not cover module mode's `automerge` block, which reads the admission's facts in the CI
  App's run, where the admission does not apply, for rules 7 and 8 of
  [Module-auto-merge.md](Module-auto-merge.md).
- **Module mode**: `_module` applies the admission before the test stage; a refusal lists every test
  file as not run and publishes `admission-refused`. Its output carries `comments`, the admission
  head alone (D21), and `create-matrix` publishes `admission-admitted` in both modes (D22). Module
  auto-merge's rule 8 applies the run's holds to the admission's facts (D30).
- **The test stage**: `tests.py`'s secrets-unavailable rule drops credentialed rows for a fork, and for
  a Dependabot run only when the admission does not apply (D20).

## 10. The workflows

Project workflow:

- `create-matrix`: checkout with fetch depth 2; the output `admission-refused`.
- The environment job's init: `lockfile-mode` is `readonly` when the actor is `dependabot[bot]` and
  the switch is on, `default` otherwise. The expression reads the event and the input, so no row
  changes.
- The conclusion: a branch on `admission-refused` before every other.
- The seed, the aggregator and the run summary render §7 from `relevance.json`.

Module workflow:

- The two inputs, the switch defaulting to `false`.
- `validate` waits for `create-matrix` and runs only when the admission did not refuse; the module
  conclusion gains the same branch.
- `seed-pr-comments`, the project workflow's seed job but for its condition, on pull requests
  Dependabot opened: the admission head (D21).
- `generate-docs` waits for `create-matrix`, whatever its result, and on a Dependabot pull request,
  or a Dependabot run, asks the App for a token only when `admission-admitted` is `true` (P26). A
  step after the checkout compares the checked-out tip with the pull request's head the run
  evaluated; the push needs both (D22, P23).
  The terraform-docs action gains a `commit-message` input, `[dependabot skip]` on Dependabot runs.

Holds (§4.6) change no job in either workflow: they are policy the engine reads, and their verdict
travels the admission's paths. The two workflows' descriptions of `dependabot-admission-yml` name
the `hold` key.

Structural tests in `structural-tests/run_all_tests.sh` change with them: F11
(create-matrix's outputs), F20 (the shared test jobs and the seed job stay equal), F21 (the module
conclusion and `validate`'s needs), F24 (the App check names the Dependabot secret on a Dependabot
run), F25 (the init expression and the conclusion branch), and F26 (the docs job's gate, pin, push
and commit message).

## 11. The module workflow, and why it is opt-in

Without the admission, a module repository's Dependabot run reaches no cloud identity: credentialed
test lanes are dropped on Dependabot runs (Terraform-tests.md §4.7), `validate` holds no
credentials, and what remains is the token and whatever Dependabot secrets the repository holds,
which in the usual module repository are none. Its tests that need credentials simply do not run on
Dependabot pull requests.

Switching the admission on is how a module repository gets every test run on them: an admitted run
runs its credentialed lanes too (D20), against the sandbox identities the lanes name, once their IDs
are plain values. A refused run runs nothing, `validate` included (D16).

Module repositories usually commit no lock file, so their providers are judged at the newest
version their constraints allow (§4.3), and D10 does not apply.

Holds work in a module repository as in a project, for what Dependabot moves there: a called
module's pin. A provider hold judges only a Dependabot change to a provider's constraint, which the
module dependency strategy does not let Dependabot make; every run installs the newest release the
range allows, held or not, so a provider release that breaks the module is kept out by capping the
range ([Module-dependencies.md](Module-dependencies.md) §4). With the admission off, `hold` is a
validation error (D29).

A Dependabot bump usually makes the README stale, since terraform-docs lists the providers'
constraints and the modules' versions (P25). On an admitted run the docs job commits the
regenerated README to Dependabot's branch (D22). That run then skips validation and the tests, as
any run whose docs job pushed does, and the run the commit starts, the App's, validates and tests
the admitted change with the generated README on top. With the admission off the README is checked,
and a stale one fails: turning the admission on is also how a module repository gets its Dependabot
pull requests green.

## 12. What stays out

- **Inspecting module content** (D9). A list of dangerous block types read from HCL text misses
  unquoted labels (`data external "x" {}` is valid), JSON syntax and escapes; plan-time code also
  comes as data sources of ordinary providers, provider functions, child `provider` and `import`
  blocks and `file()`; and upgrades of trusted modules add providers and examples as a matter of
  course. What would stop a malicious version is not reading it but who may publish it, and when.
- **A read-only plan identity** (§1).
- **A person in the loop**, **an AI review**, **a GitHub App or custom deployment protection rule**:
  decided by the maintainer.
- **Credential-free checks for a refused run**: possible in a job that references no secret, has no
  GitHub Environment and only read permissions, but a refused run is red and a person acts on it
  anyway.
- **Keeping Dependabot from opening a held pull request.** That is Dependabot's `ignore`, which lives
  in the `.github/dependabot.yml` the organisation's configuration writes for every repository.
  A later central step can write each hold into it; the hold stays the guarantee, since `ignore`
  chooses the version Dependabot reports, not the one the lock records (P31). A hold maps to one
  `ignore` entry, Dependabot's names compared without case and its `*` matching any characters:

  | Hold | `ignore` entry |
  |---|---|
  | `provider: hashicorp/azurerm`, `versions: "> 3.116.0, < 4.12.0"` | `dependency-name: "hashicorp/azurerm"`, `versions: ["> 3.116.0, < 4.12.0"]` |
  | `module: Azure/naming/azurerm` | `dependency-name: "azure/naming/azurerm"`, the same `versions` |
  | `module: github.com/<owner>/<repo>` | `dependency-name: "*::github::<owner>/<repo>::*"`: Dependabot names a GitHub module `<module label>::github::<owner>/<repo>::<ref>` |

  A provider declared without `source` is named by its local name in Dependabot (`azurerm`), and
  needs a second entry.
- **Holding a person's change.** A hold is for the automation; a person's upgrade is a decision of
  its own (§3). The audit warns when one reaches a committed lock or pin (D27).
- **A date on a hold** (D28).

## 13. Compatibility and migration

This ships as a minor release (`feat:`). What a caller on `@v1` sees:

- A Dependabot pull request that is not admitted is red with the admission comment, where before it
  ran: a plan with the apply identity for a caller with plain-value IDs, or an authentication failure
  for a caller with secret IDs. **A Dependabot pull request that was green can turn red**, which the
  commit and the release notes say in so many words.
- Dependabot auto-merge stops for a version younger than `min-age-days` until the run is re-run.
- **An admitted Dependabot run runs credentialed test lanes**, which were listed as not run; a lane whose
  credentials are still environment secrets fails there (D20). This is a behaviour change for callers
  on v1 with credentialed lanes, shipped in a minor release by the maintainer's decision while few
  callers are on v1, and said in so many words in the commit and the release notes.
- `relevance.json` gains `admission`; `create-matrix` gains `admission-refused`; the comments gain the
  admission head and the `not-admitted` head body. Check names are unchanged.
- Nothing changes for any other run, and nothing at all with `dependabot-admission-enabled: false`
  (D14).

The precedent is the 1.1.0 change that stopped scheduled runs applying unless the caller sets
`schedule-goal: default`: a stricter default with a caller-side way back, shipped as a minor.

For an admitted Dependabot run to plan, a caller changes two things, which the migration guide and the
user guide gain:

1. **Azure IDs as plain values** (D18), per environment:

   ```yaml
         environments-yml: |
           - environment: prod
             extra-envs-yml:
               ARM_TENANT_ID: "00000000-0000-0000-0000-000000000000"
               ARM_SUBSCRIPTION_ID: "00000000-0000-0000-0000-000000000000"
               ARM_CLIENT_ID: "00000000-0000-0000-0000-000000000000"
   ```

   Migration-v0-to-v1.md §2.7 rule 1 is sharpened to match: credentials stay environment secrets;
   identifiers are plain values.
2. **The documented permissions instead of `write-all`**, so a Dependabot run's token cannot write.
3. **Test lane IDs as plain values** in each credentialed lane's `extra-envs-yml`, the lane keeping its
   GitHub Environment for its OIDC subject; a secret a test needs beyond the IDs becomes a
   Dependabot secret (D20).

A caller that keeps secret IDs is still protected: an admitted run fails on the missing secret, as
it does today, and a refused run runs nothing.

**Holds** (§4.6) ship in a minor release of their own (`feat:`). Without `hold` nothing changes: no
fact is gathered, no verdict differs, and only the two messages that list the policy's keys name
`hold` too. A caller pinned to a release before holds that sets `hold` gets the unknown-key error,
not a hold that does nothing.

## 14. Residual risks

| # | Risk | Why it stays |
|---|---|---|
| R1 | A trusted publisher's account is taken over and a signed, malicious release survives `min-age-days` unnoticed. | Nothing short of reviewing a binary catches it, and the version would run on the default branch after merge anyway; it is the risk of every bump a person makes. |
| R2 | An admitted run's jobs hold every Dependabot secret the repository has. With D18 that is the auto-merge App's key, where Dependabot auto-merge is set up, and the App mints tokens for every repository it is installed on. | Delivery follows references (P2) and the export steps reference every secret. A repository without Dependabot auto-merge holds no Dependabot secret. |
| R3 | Versions resolved transitively, nested modules and directories without a lock beyond the constraint the pull request changes, are not checked for age or key. | The allow list applies to what the pull request changes; Terraform resolves the rest at `init`. |
| R4 | Module content is not inspected (D9). | §12. |
| R5 | The registry's version detail endpoints are undocumented. | A change in their shape fails `create-matrix` (D11) rather than admitting. |
| R6 | An admitted Dependabot run's credentialed test lanes run the pull request's dependencies with the lanes' identities. | The same decision as for the environments (D3); a lane identity reaches a sandbox only, by the isolation preconditions of Terraform-tests.md §3.6. |
| R7 | The run a docs commit starts on an admitted Dependabot pull request is the App's, not Dependabot's: it reads the repository's Actions secrets, and the admission does not judge it (D22). | It carries the admitted change and the generated README only (P23), whose dependencies the admission judged minutes before, and the admitted run already held the App's key as a Dependabot secret; a module repository's other Actions secrets are what an admitted release reaches beyond R1. The key itself reaches what the App can write, so the App is installed on the module repositories alone. With auto-merge on, the key also merges ([Module-auto-merge.md](Module-auto-merge.md) R2). |
| R8 | A hold does not change what `init` installs: where nothing locks a dependency, a held release inside its constraint runs without any pull request (§4.6). | The constraint keeps it out there ([Module-dependencies.md](Module-dependencies.md) §4); in a project's environments the lock does (D10). |
| R9 | A pull request whose run predates the hold, re-runs of that run included, stays mergeable by a person until its next new run (P37). | Auto-merge pins its merge to the base the run saw ([Auto-merge.md](Auto-merge.md) §6), and module auto-merge applies the hold in the App's run (D30), so only a person's merge is left; after adding a hold, rebase the dependency's open pull requests. |
| R10 | A person's change is not held. | The hold is for the automation (§12); the audit warns when a held version reaches a committed lock or pin (D27). |

## 15. Examples

| Pull request | Verdict | Why |
|---|---|---|
| `hashicorp/azurerm` 4.41.0 → 4.42.0 in two environments' locks, published 6 days ago, same key | admitted | every check passes |
| a lock-only bump of `azure/azapi`, published 4 days ago | admitted | lock-only is a valid shape; `Azure` is built in (without case) |
| `cyrilgdn/postgresql` 1.25.0 → 1.26.0 | not admitted | `allow` |
| the same, with `cyrilgdn/postgresql` in `allow` | admitted | |
| `Azure/naming/azurerm` 0.4.3 → 0.4.4, published 1 day ago | not admitted | `age`; admitted on a re-run after day 3 |
| `dsb-norge/mgmt-resource-lock/azurerm`, published an hour ago | admitted | `dsb-norge` is exempt from `min-age-days` |
| a GitHub module `github.com/<org>/<repo>?ref=v1.3.0`, owner allowed, tag without a release | not admitted | `age`, unless the owner is exempt |
| a partner provider whose new version is signed by a new key carrying HashiCorp's partner trust signature | admitted | `key`: HashiCorp vouches (D8) |
| a partner provider whose new version is signed by a new key without a trust signature (Terraform: "self-signed") | not admitted | `key` |
| a pull request titled "4.4.0 to 4.81.0" whose lock records 5.8.0, published nine hours before | not admitted | `age`, judged on the lock (P16) |
| a Dependabot pull request a person has pushed a commit to | not judged on that push | the person's run |
| the same pull request after `@dependabot recreate` | judged | the actor is Dependabot again |
| a pull request that also changes `.github/workflows/ci.yml` | not admitted | the shape |
| an admitted pull request in a repository whose lane `oidc` has its IDs as plain values | admitted; the lane runs | D20 |
| the same with the lane's IDs still environment secrets | admitted; the lane fails its credential check | D20, P19 |
| a refused run with `dependabot-admission-enabled: false` in the caller | not judged | D14 |
| the registry answers 503 for one version | `create-matrix` fails naming the fact | D11 |
| `hashicorp/azurerm` 3.116.0 → 3.117.1 in two environments' locks, with the hold `provider: hashicorp/azurerm`, `versions: "> 3.116.0, < 4.12.0"` | not admitted | `hold`; the report gives the range and the reason |
| a lock-only bump of `hashicorp/azuread` in the same repository | admitted | no hold names it (§4.6, I30) |
| the hold and the pin back to 3.116.0 in one pull request of a person's; Dependabot proposes 3.117.1 the next night | not admitted | the next run's merge commit carries the hold (§4.6) |
| `Azure/naming/azurerm` 0.4.4 → 0.5.0, called as `Azure/naming/azurerm//modules/x`, with the hold `module: azure/naming/azurerm`, `versions: ">= 0.5.0"` | not admitted | the package is held, without case |
| `git::https://github.com/<org>/<repo>.git?ref=v1.4.0` → `v2.0.0`, with the hold `module: github.com/<org>/<repo>`, `versions: ">= 2.0.0"` | not admitted | every GitHub source form is the repository |
| the same module from `?ref=v1` to `?ref=v2`, with the same hold | not admitted | `v2` is not a version a hold can compare (D26) |
| a pre-release `4.0.0-beta1`, with the hold `versions: ">= 4.0.0"` | not admitted | its release is in the range (D26) |
| a pre-release `4.12.0-rc1`, with the hold `versions: "> 3.116.0, < 4.12.0"` | not admitted | its place in version order is in the range (D26) |
| two holds on `hashicorp/azurerm`, `">= 4.0.0, < 4.12.0"` and `"= 3.117.1"`, and a bump to 3.117.1 | not admitted | the second covers it; the report gives that one |
| `hold` set with `dependabot-admission-enabled: false` | `create-matrix` fails | D29 |
| `versions: [">= 3.117.0", "< 4.0.0"]`, `versions: 3.117` or `versions: ""` | `create-matrix` fails | one string, quoted, naming a version (§6) |
| the hold `provider: hashicorp/azurem` (a typo) | every run warns: it matches nothing | D27 |
| `versions: "3.116.0"`, meant as "keep 3.116.0", while the locks record 3.116.0 | every run warns: the locks record a held version | D27, P35 |
| a person's pull request moves a lock to 3.117.1 | not judged; its run, and every run after, warns | D27, R10 |
| a pull request refused as too new before the hold landed, then re-run with "Re-run all jobs" | admitted: the re-run reads the calling workflow of its old merge commit | P37, R9 |

## 16. Pitfalls

| # | Pitfall | Consequence | Rule |
|---|---|---|---|
| P1 | The environment job's OIDC subject is its GitHub Environment's, the same on a pull request as on the default branch. | A Dependabot run with the client ID mints the apply identity's token. | Not admitted runs nothing (D4). |
| P2 | A job receives every secret its YAML references, whether or not the step runs, and `toJSON(secrets)` references all (verified on the test bed: a job referencing `toJSON(secrets)` in a step with `if: false` had both test secrets masked; one referencing a single secret had only that one; one referencing none had none). | Every environment and test job of a Dependabot run holds every Dependabot secret. | D4; R2. |
| P3 | A commit created through the API with any author is shown as that author; GitHub signs bot commits only without custom author information, so a forged Dependabot commit is unsigned, but nothing documents a signed one as proof. | An authorship rule adds nothing a content rule does not cover. | D5. |
| P4 | A re-run keeps the actor and the event, but "Re-run failed jobs" does not re-run a `create-matrix` that succeeded. | A version that has aged is still refused on that kind of re-run. | The help says "Re-run all jobs" (§7); D11 fails `create-matrix` itself for a missing fact. |
| P5 | Dependabot's own pushes to its branch start `push` runs on callers that trigger on every branch, on the pull request's head commit. | Two `Terraform conclusion` checks on one commit. A required check then needs both to pass, in whichever order they finish (verified on the test bed: red then green, and green then red, both block; green and green merges). | D17: the push run is green. |
| P6 | The updater regenerates a lock block and re-pads its `version` line. | A text comparison of the lock sees changes that are not. | Parsed comparison (§4.1). |
| P7 | The registry reports `Azure`, lock files `azure`. | A case-sensitive allow list refuses Microsoft's providers. | Without case (D6). |
| P8 | A module upgrade can require a provider the lock lacks, implicitly through a data source's type. | In `init`'s default mode Terraform installs the newest matching version, records it and runs it, unjudged. | `-lockfile=readonly` on Dependabot runs (D10). Verified with Terraform 1.16: the new provider is downloaded and its signature checked, `init` fails with "Provider dependency changes detected", and `validate` ("Missing required provider") and `plan` ("Inconsistent dependency lock file") refuse with no provider plugin started. A module needing a newer version of a locked provider fails `init` in either mode, downloading nothing. |
| P9 | Commit and tag dates are set by the client; the registry's module tags are often lightweight. | A backdated commit passes an age check. | The release's `published_at` (§4.4). |
| P10 | A publisher's key changes for new versions only. | `key` refuses the release. Seen on a partner provider: its earlier versions are "signed by a HashiCorp partner", the next is "self-signed" with a new key that carries no partner trust signature. | A maintainer looks before it runs and updates the lock by hand; the help names both keys and Terraform's verdict on each. A rotation to a key HashiCorp vouches for passes (D8), and one that re-signs every release, as HashiCorp's in 2021, does not change the key at all. |
| P11 | The registry's `verified` flag is false for some modules of a trusted publisher. | A rule on the flag refuses them. | The allow list, not the flag (D6). |
| P12 | Admission facts gathered on every run would spend the token's hourly budget and the registry's patience. | Rate limits on busy repositories. | Gathered only when the admission applies (§8); the change read through git, not the API. |
| P13 | A configuration error raised as an engine error exits before `relevance.json` is written. | No report, no artifact for the readers. | A refusal is a participation drop, not an error (§9). |
| P14 | The seed's "not affected" body is chosen for any skip that is not a trigger-events one. | A refused environment would read "no changed file matches". | The `not-admitted` head state (§7, §9). |
| P15 | A caller keeps secret IDs. | An admitted run fails on "secret not available". | The migration items (§13); the message names the secret, as today. |
| P16 | Dependabot picks the version it reports by its cooldown and ignore rules, then regenerates the lock with `terraform providers lock`, which takes the newest version the constraints allow. | Seen: a pull request titled "4.4.0 to 4.81.0" locked 5.8.0, a major version published nine hours before, past the caller's five-day cooldown and its ignore of major versions. | The admission judges the lock, what runs, never the title: `age` refuses it. |
| P17 | Python's `urllib` tries the addresses in resolver order and does not race IPv4 against IPv6. | On a host that resolves the registry's AAAA records without working IPv6, each call waited about 25 seconds before falling back. | Registry calls through `curl` (§8). |
| P18 | A partner key's trust signature covers the key's de-armoured bytes, not its armour text, as Terraform's `package_authentication.go` decodes both before checking. | Verifying over the text fails for every partner key. | Verify over the decoded key (§8). Verified with `gpg` against HashiCorp's partner key: two partners' keys good; another partner's signature over the same key and a key with one bit flipped bad. A trust signature that does not verify makes Terraform refuse the package outright, not fall back to "self-signed"; the admission refuses it as `key`. |
| P19 | The lane credential check's message says the lane's environment "has no ARM_TENANT_ID or ARM_CLIENT_ID secret yet". | On a Dependabot run the secret may well exist and still not arrive; the message sends a maintainer to set a secret that is already set. | On a Dependabot run the message says that environment secrets do not reach Dependabot runs and names the plain-value `extra-envs-yml` in the lane (D20). |
| P20 | The adapter traces a changed `version` line to its dependency; a line it cannot trace (a legacy `provider` block, an unusual layout) would have passed the shape rule, which sees a change inside a version, and been judged by nothing. | A dependency admitted unchecked. | The adapter reports such lines as `unmapped`, and the engine refuses them (§4.1). Found by the mutation gate, through a mutant in the header scan that no test noticed. |
| P21 | The directories of `terraform-init-additional-dirs-yml` are initialised with a writable lock on a Dependabot run too. | `init` there downloads and records a provider the environment's lock does not have. | Nothing runs it: those directories get `init` only, for TFLint; `validate` and `plan` run in the environment root, whose `init` reads the lock only (D10). Seen on the test bed: an admitted run's additional directory, which has no lock, installed the newest `hashicorp/azurerm`. |
| P22 | A Dependabot run's `init` reads the lock only (D10), so it cannot add the `h1:` checksum of the runner's platform to a lock entry that lacks it. | `init` installs the package, verified against its `zh:` hash, and passes with "Provider lock file not updated"; `validate` then fails: "the cached package … does not match any of the checksums recorded in the dependency lock file". A person's run adds the checksum and passes, so only Dependabot's runs fail. | `verify-lock-file`, on by default, keeps `linux_amd64` in every lock entry. Seen on the test bed, which runs with it off: an entry made on `linux_arm64`. |
| P23 | The module docs job checked out the pull request's branch by name, so its tip, not the commit the run evaluated. | Had Dependabot pushed a newer commit since, a docs commit on top of it would start the App's run, which nobody judges, on a dependency nobody admitted. | A step compares the checked-out tip with `github.event.pull_request.head.sha` and the push needs it to match; the push is a plain `git push`, which GitHub refuses when the branch moves after the check (D22). |
| P24 | Dependabot stops rebasing and updating a pull request once a commit of anyone else's is on its branch. | After a docs commit the pull request would be left behind its base and never moved to a newer version. | The docs commit's message carries `[dependabot skip]`, which Dependabot ignores: it keeps rebasing, the rebase drops the commit, and the next admitted run commits the README again. |
| P25 | terraform-docs lists the providers' constraints and the modules' versions in the README, as the module template configures it, and a Dependabot run never got a docs commit. | Every Dependabot bump in a module repository failed the docs check, admitted or not (seen on the test bed). | D22. |
| P26 | The module docs job's App token was keyed on the run's actor alone, `github.actor != 'dependabot[bot]'`. | A person's run on a Dependabot pull request (reopened, labelled, edited) is not Dependabot's, so the token was minted and the README committed on a change the admission never judged, and the App's run that followed was judged by nobody either; module auto-merge would accept that docs commit. | The token is also keyed on the pull request's author: on Dependabot's pull request it is minted only when the run was admitted ([Module-auto-merge.md](Module-auto-merge.md) M4). |
| P27 | The Dependabot runner type is **Labeled runner** (repository or organization setting) with no runner of that label, or a runner group the repository has no access to. | Every update job stays queued for a day and is cancelled, so Dependabot never opens a pull request, and nothing reports it: the admission never has anything to judge (seen in several calling repositories). | The runner type set to **Standard GitHub runner**, which the update job needs nothing beyond; [Migration-v0-to-v1.md](Migration-v0-to-v1.md) §2.13. |
| P28 | A registry module named with a subdirectory, `<namespace>/<name>/<provider>//<subdirectory>`, was not recognised as a registry source. | Its every bump was refused as "neither a registry.terraform.io module nor a GitHub source", so no such pull request could be admitted (seen in a calling repository, on a firewall policy module's rule collection groups). | The registry source takes an optional subdirectory, as the GitHub sources did; the package is judged (§4.2). |
| P29 | Dependabot rewrites a lock only for a provider it bumps. A module's new version that changes a provider constraint leaves the environment's lock recording the old constraints. | The lock check failed with `Lock file out of date` on every such pull request, so none could pass, admitted or not, until a person committed the line (seen on a key vault module's bump in a calling repository). | The check warns on a constraints-only difference and the step succeeds; the versions and hashes stay strict ([Terraform-tests.md](Terraform-tests.md) §9.10, D23). |
| P30 | Dependabot's Terraform updater picks the newest version without reading the constraint, then rewrites a constraint the new version does not satisfy: it replaces an exact version, moves a `~>`, raises a `<` or `<=` and drops `!=` ([`requirements_updater.rb`](https://github.com/dependabot/dependabot-core/blob/main/terraform/lib/dependabot/terraform/requirements_updater.rb)). | A cap written into the code is rewritten by the pull request it should stop. | Holds (D23). |
| P31 | Dependabot's `ignore` and cooldown choose the version it reports; the lock is regenerated by `terraform providers lock`, which takes the newest version the constraints allow (P16). | An ignored version can still land in the lock. | The hold judges the lock's version (§4.6). |
| P32 | Terraform's range operators never select a pre-release. | Read as Terraform reads it, a hold would let every pre-release through, and Dependabot proposes pre-releases to a repository already on one. Judged by its release alone, `4.12.0-rc1` would pass `< 4.12.0`. | A pre-release is held when its place in version order or its release is in the range (D26). |
| P33 | A ref such as `v3` is a moving tag, and Dependabot updates refs of that shape. | Read as 3.0.0, it escapes `>= 3.117.0` while pointing at 3.117.1. | A ref that is not `X.Y.Z` cannot be compared, and a held module with one is held (D26). |
| P34 | The admission's constraint reader, `allows()`, allows every release for an empty constraint, stops at the first condition a version fails, so a later unreadable condition goes unseen, and accepts the `v` prefix Terraform refuses. | A hold read with it could hold nothing, or hold differently from what Terraform's reading of the same text says. | Holds have a reader of their own that reads every condition; validation refuses an empty, unreadable or `v`-prefixed range, a pre-release in a condition, a YAML number and a range no release satisfies (§6). |
| P35 | `versions` is the versions kept out, where a Terraform constraint is the versions allowed. | `versions: "3.116.0"`, meant as "keep 3.116.0", holds 3.116.0 and lets 3.117 through. | The audit warns that a hold covers what a committed lock records (D27); every example comments the key. |
| P36 | The admission head's last paragraph invites running the pull request once with a person's commit. | For a held version, it invites running what the repository decided against. | Left out when every failed check is `hold` (§7). |
| P37 | A pull request's run reads the calling workflow from its merge commit, and a re-run keeps that commit. | A hold, or a lifted one, does not reach an open pull request until its next new run; one that is green already stays mergeable by a person, and one refused as too new, re-run as the `age` help says, is admitted at a held version. | After adding or lifting a hold, `@dependabot rebase` (§4.6); auto-merge's base pin refuses the merge of a run older than the hold; R9. |
| P38 | Dependabot stops rebasing a pull request on its own once it has been open for 30 days, and says so in its body ("Automatic rebases have been disabled on this pull request as it has been open for over 30 days"). The `@dependabot rebase` command still works at any age: on public pull requests 32 to 819 days old, every such command in October 2026 was answered with a rebase within minutes, or with "up-to-date" or "edited by someone other than Dependabot", never with a refusal for age. | A long-held pull request falls behind its base and stays there. | Nothing needed: the help's `@dependabot rebase` is the way back at any age (§18). |
| P39 | A refused pull request counts towards Dependabot's limit of open pull requests, five per configuration entry unless the configuration says otherwise. | A held pull request takes a slot for as long as it is open. | Accepted with D31; the help says so. |
| P40 | Closing a Dependabot pull request makes Dependabot delete its branch and answer "OK, I won't notify you again about this release, but will get in touch when a new version is available". Every later update job lists the closed pull request among its existing pull requests, by dependency and version but not by directory, and opens none for that version ("Pull request #<n> already exists for <dependency> with latest version <version>"). It is not an ignore condition: the job's `ignore-conditions` stay empty, so `@dependabot show … ignore conditions` does not list it. | A held pull request closed by hand keeps that version away after the hold is lifted, in every directory: on the test bed, a pull request closed six days before, for a directory since removed, kept its version out of a new directory. A newer version gets a pull request of its own. | D31; the help says so. A close is undone by restoring the branch at the pull request's head, reopening it and commenting `@dependabot rebase`: reopening alone drew no reaction, the command rebased it onto the base within a minute (§18). |
| P41 | Heads are found by a substring of their marker. | A reason holding `<!-- tf:head:` would match another head. | `<` in a reason is escaped (§7). |
| P42 | Holds are per calling workflow (D24). | In a repository with two calling workflows, one without the hold admits the pull request and plans it, and merges it where only its conclusion is required. | Declare the hold in each calling workflow. |
| P43 | The module workflow's docs commit starts a run the admission does not judge (D22). | A hold landing between Dependabot's admitted run and the docs commit is on the base the App's run merges against. | Module auto-merge's rule 8 applies it (D30); the App's run still validates and tests the held version (R7), and only the merge is stopped. |
| P44 | A module's new version can require a provider version the lock does not have. | Under D10 `init` fails (P8); moving the lock to satisfy it can move it into a hold, which no admission judges, since the change is a person's. | The audit warns on that person's pull request (D27). |

## 17. Tests

**Must:**

- Engine, table cases: each row of §15; each check failing alone; credentialed test rows kept on an
  admitted Dependabot run, dropped on a fork and on a Dependabot run with the admission off; a
  grouped pull request (three dependencies across four directories, one failing); a lock-only change;
  a constraint rewritten with `!=` dropped; `.tf.json`, a Terragrunt `.hcl`, an added file, a rename
  and a mode change refused;
  case-insensitive allow and exempt matching; the key check with the same key, HashiCorp's own key, a
  partner trust signature that verifies, one that does not (a tampered signature, another key's), and
  none; the built-in lists extended, not replaced; constraint
  resolution over a version list (each operator, pre-releases, a constraint nothing satisfies).
- Engine, invariants I26 to I29, each with a broken output it catches (`test_invariants.py`), and the
  mutation gate over `admission.py`.
- Engine, validation: every message of [Configuration-validation.md](Configuration-validation.md)
  §3.9, and the inputs refused per environment.
- Adapter: each fact of §8 answered, missing, mistyped and erroring; the trust signature verified
  with `gpg` against recorded registry answers, valid and tampered; a 404 for a release read as "no
  release"; the diff read from a two-commit checkout; the input-document log free of inventories.
- Workflows: the structural tests of §10; the conclusion's run block on `admission-refused` with
  `allow-failing-terraform-operations: true`; the module docs job's pin step run against a
  repository whose tip is at, and past, the evaluated head.
- Renderers: the admission head, the `not-admitted` environment and group bodies, the run summary
  section, and the admission head deleted on a later run, in both modes; in module mode no head where
  the seed does not run (a push, a fork, `add-pr-comment: false`).
- Holds, engine: each matching form of §4.6 (a provider with and without `registry.terraform.io/`, a
  registry module called through a subdirectory, each GitHub source form, mixed case, `.GIT`), and a
  hold that names another dependency passing; each condition operator at its boundary, `~>` with
  one, two and three segments, a pre-release held through its release and through its order, a ref
  that is not `X.Y.Z` held;
  two holds on one dependency, each reported; every hold message of Configuration-validation.md
  §3.9, the YAML number and the list among them, and `hold:` empty; `hold` with the switch off; I30
  with a broken output it catches; the reader of hold ranges and the `hold` check under the mutation
  gate. Literal expected values, never the module's own constants.
- Holds, audit: each warning; none without `hold`; none for the dependencies a judged pull request
  changes; a provider without `source` that a lock records matched through the lock; a file that
  cannot be read named in a warning and the step green; the verdicts of a run equal with and without
  the inventory.
- Holds, renderers: no `hold` check listed without holds, and the port and admission goldens
  unchanged; the row with one range, two, a `~>` reading and an unreadable version; the help
  with the reason collapsed and `<` escaped; the last paragraph left out when every failed check is
  `hold` and kept when another check fails too.
- Holds, module auto-merge: rule 8 in Dependabot's run and in the App's run (Module-auto-merge.md
  §9).

**Should:**

- Port cases: unchanged (the inputs gain the two keys, no row changes).
- Seed and aggregator suites: a refused run alongside groups and held-back rows.

**Could:**

- A contract test of the registry answers, run on a schedule, so an endpoint's drift is seen before a
  Dependabot run meets it.

**On the test bed**, when built: admitted and refused Dependabot pull requests, a push run, a
re-run after the minimum age, a module bump needing a new provider under `-lockfile=readonly`, the
module workflow opted in, and an admitted module pull request's README committed by the docs job.
For holds: a held provider bump refused with its reason; the same provider bumped outside the hold
admitted; the hold lifted and `@dependabot rebase` admitting the pull request; the audit's warnings
on the pull request that adds a hold without the pin; a held called module in the module workflow.
Already run there (§18): what Dependabot does when a refused pull request is closed, reopened and
rebased.

**What tests cannot cover**: whether an admitted release is benign (R1).

## 18. Open questions

What a local Terraform, the live registry, 119 real Dependabot pull requests and a probe on the test
bed could answer is answered in the text above: `-lockfile=readonly` and a new provider (P8), the
shapes Dependabot writes (§4.1), two checks of one name on one commit (P5) and the registry's load
(§8). None remain for the admission as built.

The two questions holds raised were answered on 2026-10-12, and none remain:

1. **Closing a Dependabot pull request still makes Dependabot skip that version** (P40), which the
   current documentation no longer says. On the test bed, a Dependabot pull request refused by the
   admission was closed: Dependabot answered that it would not notify about this release again and
   deleted its branch. Its next update job, whose log lists the closed pull request among the
   existing ones, opened none for that version, and a pull request closed six days before, in a
   directory since removed, kept its version out of a new directory. Reopening the pull request,
   with its branch restored, drew no reaction from Dependabot within seven minutes; `@dependabot
   rebase` then started an update job that rebased it onto the base within a minute.
2. **`@dependabot rebase` works on a pull request of any age** (P38). The 30-day rule stops
   automatic rebases only
   ([GitHub changelog, 2023-04-13](https://github.blog/changelog/2023-04-13-automatic-rebases-on-dependabot-pull-requests-stop-after-30-days-of-inactivity/):
   "You will still be able to manually rebase and merge the pull request"). Public pull requests 32
   to 819 days old, whose bodies said automatic rebases were disabled, were rebased within minutes
   of the command in October 2026; no answer to it mentioned their age. The help therefore names
   `@dependabot rebase` alone.

## 19. Implementation order

1. Engine: the input key and its shape check, `admission.py`, rule 3a, the output block, the
   vocabulary, the invariants, tests and the mutation gate.
2. Adapter: the facts of §8 and D11.
3. Configuration: the inputs in both workflows, validation, Configuration-validation.md.
4. Project workflow: checkout depth, the init expression, the conclusion branch, the renderers, the
   structural tests.
5. Module workflow.
6. Documentation: the user guides (the default workflow's example 13 among them),
   Migration-v0-to-v1.md §2.7 and its checklist, Decision-engine.md §6 and §7,
   Workflow-pr-comments.md, Terraform-tests.md §4.7.
7. Test bed: the cases of §17.

Holds (§4.6) follow in the same order, in a release of their own:

1. Engine: `hold` in `settings()` and its messages, the reader of hold ranges, the `hold` check, I30,
   the audit, tests and the mutation gate; the module record's `provider`; I28's check in
   `engine/tests/invariants.py` leaving out module mode's `automerge` block, as Decision-engine.md
   states it.
2. Adapter: the module's package (§8) and the audit's inventory.
3. Renderers: the row, the help and the last paragraph's rule.
4. Module auto-merge's rule 8.
5. The two workflows' input descriptions.
6. Documentation: this spec's status line, Configuration-validation.md §3.9, the user guides, Module-dependencies.md,
   Module-auto-merge.md, Decision-engine.md.
7. Test bed: the cases of §17 and the questions of §18.

### Where each piece lives

| Piece | Place |
|---|---|
| the checks, `hold` included, and the audit | `engine/dsb_tf_engine/admission.py` |
| the rule's placement and the drop | `engine/dsb_tf_engine/decide.py`, `triggers.py` |
| the facts, the audit's inventory included | `engine/dsb_tf_engine/admission_facts.py`, called from `adapter.py` |
| the input's validation | `engine/dsb_tf_engine/admission.py` (`settings()`); the workflow-only rule in `environments.py` |
| the heads | `engine/dsb_tf_engine/comments.py`, the seed job, `aggregate-validation-summaries/` |
| module auto-merge's rule 8 | `engine/dsb_tf_engine/automerge.py` |
| the run summary | `create-run-summary/` |
| the conclusion | the `conclusion` job of both workflows |

## 20. What implementation taught the spec

- **The pull request's author is a fact.** Purging a stale admission head on every pull request run
  would have changed every run's manifest and broken I14; only a Dependabot-authored pull request can
  hold one, and its author survives a person's push. The adapter reads `pull_request.user.login`.
- **A constraint that resolves to the same version is no dependency.** In a directory without a lock,
  `~> 2.6` and `~> 2.12` both resolve to the newest 2.x: `init` installs what it installed before, so
  nothing new runs and nothing is judged.
- **The adapter hands over changed lines, not only inventories.** The shape rule is the engine's, so it
  needs each changed line pair of a `.tf` file and each lock parsed; whole files never enter the
  document.
- **Three faults the tests found in the first draft:** the switch accepted `1` (`1 == True` in Python;
  compared by identity now); a `version` written after a comma in a one-line `required_providers`
  entry was not read, so an empty constraint resolved to the newest major; and the line of an argument
  was counted from the start of its block's body, one line too early.
- **`allow` that is neither a list nor a string** gets a message of its own (Configuration-validation.md
  §3.9).
- **A version change nothing explains is refused** (P20). The mutation gate's survivors in the `.tf`
  scan showed that a line the adapter could not trace was skipped silently; the adapter now reports it
  and the engine refuses it. The scan also reads a block's header after a comment or heredoc on its line.
- **The module workflow's `validate` waits for `create-matrix` only on a Dependabot run**, so a refused
  configuration elsewhere still shows validation's result as before.
- **A held run's relevance notice is the change's.** On the test bed a refused run printed
  `0 of 4 environments affected; nothing to verify for this change` for a change that touched one
  environment: the notice counted verdicts after rule 3a had dropped them all. It is computed before
  rule 3a now, so a held run says what the change touches and the admission's notice says why nothing
  runs.
- **Dependabot rewrites only the block form of `required_providers`.** The test bed's first probe wrote
  each provider on one line; every provider update failed in Dependabot's job with "Content didn't
  change!" and only the module pull requests opened
  ([user guide](Workflow-terraform-ci-default.md#dependabot-pull-requests-the-admission)).
- **A move between two self-signed keys fails the key check too.** A community provider on the test bed
  signed its new major with another self-signed key; the help said "a drop to self-signed", and says
  "a new key HashiCorp does not vouch for" now.
- **The module workflow reported nothing on a refusal** (D21). On the test bed a refused module pull
  request ran nothing and showed no comment, while its conclusion pointed at "the admission comment":
  the project workflow's seed job posts the head, and the module workflow had none. It has the same
  job now.
- **A module's Dependabot pull requests were red at the docs check, admitted or not** (P25, D22). The
  template's README lists versions, and the docs job never committed on a Dependabot run.
- **Configuration variables reach a Dependabot run; Actions secrets do not.** Verified on the test bed:
  a run Dependabot started read a repository variable and an organisation variable. The docs job's App
  ID therefore comes from its organisation variable on every run, and only the key needs to be a
  Dependabot secret as well (D22).
- **A held check carries its holds.** The `hold` check lists the holds that cover the version, each with
  its name, range and reason, so the admission head renders the reason from the verdict alone, without
  reading the policy again; the run summary and the aggregator read `checks` by `ok` and `detail` and
  pass the extra key by.
- **The module record lacked its provider.** The adapter computed a registry module's provider, the third
  part of its source, and dropped it; a hold names the package with it, so the record carries it now.
- **I28 was never checked where module auto-merge reads the facts.** Its check compares the whole output,
  and the CI App's run, where the admission does not apply, carries an auto-merge block and notice that
  read the admission's facts for rule 7. The checker leaves both out now, which the run the docs commit
  starts needs for rule 8 as much as for rule 7; it never failed, since no test ran the checker on that
  run.
