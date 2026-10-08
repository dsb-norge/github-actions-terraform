# Notifications

Authoritative spec for Microsoft Teams notifications from
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): when an
environment on the default branch is left unapplied with nobody watching (an apply that failed after
a merge, a stage held back, a cancelled run), a message reaches the right Teams channel and names, and
later mentions, the people whose change it was.

Status: **built, but for reminders (§10), mentions and direct messages (D11), the identity App
that resolves people for them (D21), and threads (§9), which wait for the relay (§13) or come with
drift detection; run end to end on a test bed (§19).** Teams-side behaviour this spec relies on was
verified against a deployed instance of the relay (§19); the open questions are in §20.
[Drift-detection.md](Drift-detection.md) specifies the drift kinds, which reuse everything here.

## 1. Why

A run on the default branch that fails is seen by whoever opens the Actions tab. In a survey of the
repositories that call this workflow, about one run in ten on the default branch failed, and the
default branch then stayed red for days, once for months while every pull request planned green.
Nobody had been told:

- GitHub's own failure e-mail goes to the account that started the run: on a merge that is the
  merger, on an auto-merge or a merge queue it is an App, and for a schedule it is whoever last
  edited the cron line. The author of the change is never told.
- The teams that own these repositories do not read GitHub's notifications, e-mail or mentions.
  They read Microsoft Teams.
- Pull-request comments and the red check reach the author while the pull request is open, which
  is not when an apply on the default branch fails.

An organisation-wide notification relay for Teams already exists,
[`dsb-norge/teams-notifier-function-app`](https://github.com/dsb-norge/teams-notifier-function-app),
deployed per landing zone with
[`terraform-azurerm-teams-notification-bot-lz`](https://github.com/dsb-norge/terraform-azurerm-teams-notification-bot-lz),
and other automation posts through it. What is missing is the pipeline reaching for it.

## 2. Decisions

| # | Decision | Rationale |
|---|---|---|
| D1 | Teams is the only channel. No pull-request comment, GitHub issue or e-mail is written to reach a person; the run summary and annotations stay as the record of the run. | Decided by the maintainer: those channels are not read. GitHub issues are also disabled in most calling repositories. |
| D2 | **The relay relays.** Every decision (what happened, whether it is worth sending, who to name, when to remind) is made here; the relay posts, replies, updates and resolves identities, and holds no Terraform or incident logic. | Decided by the maintainer: the relay is shared by several callers, and a capability added to it must be general. |
| D3 | Three jobs: **decide** and **record**, holding no identity that can change anything, on the workflow's `runs-on` like every job without an environment, and **deliver**, one job per sending environment (D16), in that environment's GitHub Environment with `deployment: false`, logging in with that environment's own identity. | The decision needs the whole run; the delivery needs an identity, and the environments' identities trust their environment's OIDC subject only ([Terraform-tests.md](Terraform-tests.md) D17). The relay's `messageId` exists only after delivery, so a third job records it. No new identity is created. |
| D4 | The jobs live in a **nested reusable workflow**, `terraform-notify.yml`, which the default workflow calls as one job. | One implementation for the default workflow and, later, the module workflow, with no copied jobs to keep equal. |
| D5 | **The target is configuration, never a default here.** Three GitHub variables name it: `TF_NOTIFY_BOT_URL`, `TF_NOTIFY_BOT_AUDIENCE`, `TF_NOTIFY_ALIAS`, at organisation or repository level. A partial set turns notifications off with a warning; it is not a validation error. | Each landing zone runs its own relay instance and channel; the organisation's GitHub configuration sets the variables per landing zone. They do not come from a pull request, so a half-finished rollout must not turn every pull request of a landing zone red. This repository is public and must not carry instance names. Variables are not secret and show in logs: acceptable because every calling repository today is a private infrastructure repository; a public caller would need the target from somewhere else. |
| D6 | **On when configured.** With the three variables present, the run notifies; `enabled: false` in `notifications-yml` turns it off. Without them nothing runs. | Decided by the maintainer: onboarding a landing zone onboards its repositories. |
| D7 | Routing per event kind in `notifications-yml`, a map keyed by kind, overridable per environment with the same key in `environments-yml`. | Most repositories configure nothing; a map keyed by kind merges per kind under the engine's existing rules, so an environment can change one kind without restating the others. |
| D8 | Incidents open on `push` and `schedule` on the default branch only, never on `pull_request` or `workflow_dispatch`. A dispatch on the default branch may **resolve** an open incident. | A pull request's author is looking at the pull request; whoever dispatched a run is looking at the run. An apply re-run by hand is the usual fix, and must close the thread. |
| D9 | The first kinds are `apply-failed`, `apply-cancelled` and `held-back`, raised only for environments whose `goals-granted` hold `apply` in the run (§4). | The three ways an environment that should have been applied ends up not applied without anybody watching. A plan-only environment is never "not applied". |
| D10 | The people are the authors of the merged pull requests, then the merger; bots are never named (§5). | The run's actor is often an App, and the merger is not always the author. |
| D11 | A person is **named** in the message from the first kind on; **mentioned**, and for some kinds **messaged directly**, once the relay mentions and messages by Entra object ID (§13). | The relay knows Teams; this repository knows GitHub (D21). |
| D12 | One Teams thread per incident, addressed by the **`messageId` the relay returns** for its first post. The record job remembers it once the relay accepted the post, and the state forgets it when the incident resolves. | Unique per post, so a new incident never lands in an old thread; general for every relay caller; no caller-chosen keys in the relay. |
| D13 | Reminders come from the next scheduled run, never from the relay (§10). | D2. An unrelated push does not retry a failed apply ([Path-relevance.md](Path-relevance.md) P16), so a scheduled run is the only clock this repository has. |
| D14 | The deliver job runs on `ubuntu-latest`; `notifications-yml` may set `runs-on`. | Decided by the maintainer: a relay instance that admits the hosted runners' egress (the `AzureCloud` service tag in its `allowed_caller_rules`) needs no firewall work per landing zone, and the token with the relay's application role is the gate. The override covers an instance that does not. |
| D15 | A notification never changes a run's conclusion: the `notify` job is outside `conclusion.needs`, every job in `terraform-notify.yml` has job-level `continue-on-error`, a timeout and `if: always()`, and the deliver matrix is guarded against being empty. | The conclusion is a required check; an outage of the relay must not block merges. Step-level `continue-on-error` does not cover a job that cannot start. |
| D16 | **`deliver-as`** names the environment whose GitHub Environment and identity send for an environment; by default the environment itself. Set it repository-wide or per environment. A sender whose GitHub Environment has protection rules (reviewers, a wait timer, a custom rule) is not used: its events are reported in the run summary with a warning naming `deliver-as`. | A protected environment would hold the deliver job for approval ([Terraform-tests.md](Terraform-tests.md) P29), or with a custom rule never start it (P27), and the user guide puts production behind reviewers ([Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md) example 2). An environment whose identity lives in another tenant than the relay names a same-tenant sender the same way. Decided by the maintainer: no further machinery for other tenants. |
| D17 | Events of the run rather than of an environment (tests failing on the default branch, a configuration rejected, an auto-merge that failed) are out of scope at first. When they join, they deliver from the first environment that ran; a rejected configuration, where nothing ran, stays in the run's annotations and the conclusion line. | Rare on the default branch: the same validation and tests run on the pull request first. |
| D18 | GitHub admin and system accounts are never mentioned or messaged. | Decided by the maintainer: those accounts carry no Microsoft 365 licence and do configuration work, not changes to infrastructure. |
| D19 | The state of open incidents is **one document per repository** in the Actions cache, merged by the record job under a concurrency lock; an observation older than the stored one is ignored (§9). | Runs overlap and finish out of order (a later run's first stage can finish before an earlier run's last), and cache entries are immutable; one document merged under a lock loses nothing, and a stale run cannot reopen an incident a newer one resolved. |
| D20 | The message is rendered and escaped in the decide job, which holds no identity that can change anything; the deliver job posts the rendered bytes and exports nothing but the sender's tenant and client ID. | The deliver job holds an apply identity; nothing from a pull request should run or be interpreted there. |
| D21 | **GitHub logins are resolved here, not in the relay.** The decide job reads each named person's SAML identity in the organisation with an installation token of a GitHub App that holds organisation Members read and nothing else, and hands the relay Entra object IDs. Without the App, messages name people and mention nobody. | Decided by the maintainer: the relay stays free of GitHub knowledge and accepts Teams identities only. `GITHUB_TOKEN` cannot read SAML identities; an installation token with Members read can. Every member's identity carries the Entra object ID (`…/claims/objectidentifier`), which survives renames, and the UPN. |
| D22 | The relay is trusted on authentication: holding its `Notifications.Send` role is the whole permission to post, to any alias of that instance. | Decided by the maintainer: each landing zone has its own instance, and only its identities hold the role there, so one landing zone cannot post into another's channels; inside one, the posting identities are apply identities that can already change production. |
| D23 | Notifications are **markdown text messages** (the relay's `format: text`), not Adaptive Cards. Links are markdown links. | Decided by the maintainer: a notification is a few lines, and a text message uses the channel's full width where a card is narrow and crowded. Mentions, tag mentions, replies and updates work for text as for cards, and markdown links do what buttons would, so the relay is asked for no `Action.OpenUrl`. |

## 3. Who meets it

| Run | Notifications |
|---|---|
| `push` to the default branch, the three variables set | decided and delivered (D8) |
| `schedule`, the three variables set | decided and delivered; carries the reminders (D13) |
| `workflow_dispatch` on the default branch, the three variables set | decided; resolves open incidents, never opens one |
| `pull_request`, a push to another branch | none |
| any run with `enabled: false`, without the variables, or with a partial set | none; the jobs are skipped |
| a run whose `create-matrix` failed | none; its annotations and the conclusion line say why |

## 4. Event kinds

An environment is **due to apply** in a run when its `goals-granted` hold `apply`: a push to the
default branch for an environment with `apply`, or a scheduled reconcile
([Dispatch-and-triggers.md](Dispatch-and-triggers.md) §4.4). Only such an environment raises the kinds
below; its result decides which.

| The environment's result | Kind | The message says |
|---|---|---|
| its apply failed, or did not run because a step before it failed; tolerated by `allow-failing-terraform-operations` or not | `apply-failed` | the first step that failed |
| its job or its apply step was cancelled | `apply-cancelled` | where it was cancelled |
| its stage did not run because an earlier stage failed or was cancelled ([Environment-ordering.md](Environment-ordering.md) §4.3) | `held-back` | the stage that failed |
| its stage failed, and its job left no metadata | `apply-failed` | that the job did not report |
| it applied successfully | resolves its `apply` incident | |
| it planned with no changes, on a schedule or a dispatch | resolves its `apply` incident | |
| it was not relevant to the change, or its goals held no `apply` | nothing | |

The outcome is read from the steps' outcomes and the stage results, never from parsed counts, which
are decoration ([Apply-and-destroy-reporting.md](Apply-and-destroy-reporting.md), the outcome
invariant). A tolerated failure leaves the run green and the environment unapplied, so it notifies.

An environment has at most one open incident per **slot**. The three kinds share the `apply` slot:
they all mean the default branch is not applied there, and they resolve alike, by the environment's
own next successful apply or clean plan. A held-back environment is not resolved by the earlier
stage recovering: the change meant for it has still not been applied. If later pushes do not concern
it, its incident stays open until a scheduled plan or a dispatch runs it, which is correct, and
without a schedule it also gets no reminders (§10). [Drift-detection.md](Drift-detection.md)
adds `pending-change` to the same slot, and the `drift` and `schedule` slots.

## 5. Who is named

The decide job's adapter walks the push's commits on the first-parent line from `before` to `after`,
and resolves each with `GET /repos/{owner}/{repo}/commits/{sha}/pulls`, keeping only pull requests
whose `merged_at` is set and whose base is the default branch. That call returns the merged pull
request for merge, squash and rebase merges alike but not who merged it, so
`GET /repos/{owner}/{repo}/pulls/{number}` adds `merged_by`. Both fit the caller's existing
`pull-requests` and `contents` grants. A `before` of all zeros, or one that is not an ancestor of
`after` (a force push), resolves the head commit only.

| The push came from | Named |
|---|---|
| merged pull requests by people | each author, then each merger who is not an author |
| a pull request by a bot (`[bot]` login or account type `Bot`) | the merger, if a person |
| a merge by an App (auto-merge, a merge queue) | the authors; the App is never named |
| a direct push by a person | the pusher |
| a direct push by an App | nobody; the channel only |
| a schedule | nobody new; an open incident keeps the people it opened with |

`mention` in §6.2 chooses which of those are mentioned once the relay can; the message always names
them, by login, in plain text. For each person to mention or message, the adapter will read the
organisation's SAML identity of the login with the identity App's token (D21), which is built with
mentions (§13):

```graphql
organization(login: $org) { samlIdentityProvider { externalIdentities(login: $login, first: 1) {
  nodes { samlIdentity { username givenName familyName attributes { name value } } } } } }
```

and takes the object ID from the attribute `http://schemas.microsoft.com/identity/claims/objectidentifier`,
the UPN from `username` and the display name from the given and family names. A login without an
identity, or whose UPN is not in `TF_NOTIFY_PEOPLE_DOMAINS`, is named and never mentioned: that is
how admin and system accounts, which live in another domain, stay out (D18). A failed lookup is a
fact like any other: the message names the person and mentions nobody. The environment jobs' metadata cannot supply any of this: it drops every key containing
`auth` ([capture-matrix-job-meta](../capture-matrix-job-meta/step_capture.sh)), `author` among them.

## 6. Configuration

### 6.1 The target

| Variable | Holds |
|---|---|
| `TF_NOTIFY_BOT_URL` | The relay instance's API base, `https://…/api` |
| `TF_NOTIFY_BOT_AUDIENCE` | The token audience, `api://<the relay's API application ID>` |
| `TF_NOTIFY_ALIAS` | The default alias: the channel every kind goes to unless routed elsewhere |

GitHub resolves a variable from the repository before the organisation. The intended layout is one
value per landing zone, set as repository variables by the organisation's GitHub configuration code
for every repository of that landing zone; an organisation with one team may set organisation
variables instead. The default workflow reads them in its own expressions (`vars.TF_NOTIFY_*`), as
the module workflows read `vars.ORG_TF_CICD_APP_ID`, and hands them to `create-matrix` through an
input of their own, `notify-target-json`, not the `toJSON(inputs)` document, whose every input is
forwarded into every row. Environment-level variables are not read.

Mentions and direct messages need three more organisation settings; without them messages name people
and mention nobody:

| Setting | Kind | Holds |
|---|---|---|
| `TF_NOTIFY_IDENTITY_APP_ID` | variable | the client ID of a GitHub App installed in the organisation with Members read only |
| `TF_NOTIFY_IDENTITY_APP_PRIVATE_KEY` | secret | its private key |
| `TF_NOTIFY_PEOPLE_DOMAINS` | variable | the UPN domains of people who may be mentioned, comma-separated |

The decide job reads them directly, as the module workflows read their App's variable and secret.

### 6.2 `notifications-yml`

A workflow input, a YAML map. Every key is optional; an empty value means the defaults.

```yaml
notifications-yml: |
  enabled: true             # false turns notifications off for the repository
  runs-on: ubuntu-latest    # where the deliver jobs run
  deliver-as: dev           # the environment that sends for every environment (D16)
  defaults:                 # every kind, unless kinds says otherwise
    mention: [author, merger]
  kinds:
    held-back:
      direct: [author]
    apply-cancelled:
      alias: tf-cancelled   # another channel on the same relay instance
```

| Key | Default | Meaning |
|---|---|---|
| `enabled` | `true` | `false` skips the jobs |
| `runs-on` | `ubuntu-latest` | the deliver jobs' runner |
| `deliver-as` | the environment itself | the sending environment (D16) |
| `defaults`, `kinds.<kind>` | | the routing of every kind, and of one kind; the keys below |
| `alias` | `TF_NOTIFY_ALIAS` | the channel |
| `mention` | `[author]` | which of the named people (§5) are mentioned: `author`, `merger` |
| `direct` | `[]` | who also gets a direct message, once the relay supports it |
| `remind` | `true` | `false` turns reminders off |
| `off` | `false` | `true` sends nothing for the kind |

The kinds are `apply-failed`, `apply-cancelled` and `held-back`; [Drift-detection.md](Drift-detection.md)
adds its own when it is built. A list may be one value written alone (`mention: author`), and
`true` and `false` may be written as text.

### 6.3 Per environment

An `environments-yml` entry may carry `notifications-yml` with every key but `enabled` and
`runs-on`, the name every merged setting has per environment
([Configuration-validation.md](Configuration-validation.md) §3.1). It merges over the global value
key by key, as every merged setting does: `kinds.held-back.alias` per environment changes that and
nothing else, and a list (`mention`, `direct`) replaces the global one. In the engine,
`notifications-yml` is a `MERGE_FIELDS` setting with its own validation; like every one, its
resolved value is written into each environment's matrix row without the suffix, as
`notifications` (`matrix.vars.notifications`, null when neither sets anything), where the decide
job reads it, held-back environments included.

### 6.4 Validation

`create-matrix` validates `notifications-yml` before any environment runs
([Configuration-validation.md](Configuration-validation.md) §3.10); a mistake fails the run on every
event, so it is found on the pull request that makes it. Every problem is reported, the global
value's once and first, then each environment's, whose messages begin
`environments-yml: environment 'prod': notifications-yml` instead of `notifications-yml`.

| Mistake | Message |
|---|---|
| not a mapping | `notifications-yml is 'off'; it must be a mapping of settings (docs/Notifications.md §6.2)` |
| an unknown key | `notifications-yml: unknown key 'kind' (did you mean 'kinds'?); known keys: defaults, deliver-as, enabled, kinds, runs-on` |
| `enabled`, `off` or `remind` not true or false | `notifications-yml: 'enabled' is 'yes'; it must be true or false`, `notifications-yml: defaults.off is 'yes'; it must be true or false` |
| `runs-on` not a label | `notifications-yml: 'runs-on' is 3; it must be a runner label` |
| `deliver-as` naming no environment | `notifications-yml: 'deliver-as' names 'dve', which is not an environment of environments-yml` |
| `kinds` not a mapping | `notifications-yml: 'kinds' is 'held-back'; it must be a mapping from a kind to its settings` |
| an unknown kind | `notifications-yml: kinds: unknown kind 'apply-fail' (did you mean 'apply-failed'?); kinds: apply-cancelled, apply-failed, held-back` |
| `defaults` or a kind not a mapping | `notifications-yml: kinds.held-back is 'off'; it must be a mapping of alias, direct, mention, off, remind` |
| an unknown routing key | `notifications-yml: defaults: unknown key 'mentions' (did you mean 'mention'?); known keys: alias, direct, mention, off, remind` |
| an alias the relay could not have made | `notifications-yml: defaults.alias is 'TF Alerts'; an alias is 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit` |
| an unknown person | `notifications-yml: kinds.held-back.mention takes author and merger, not 'owner'`; not a list at all: `… is 5; it must be a list of author and merger` |
| `enabled` or `runs-on` per environment | `environments-yml: environment 'prod': notifications-yml: 'enabled' is workflow-wide; set it in the notifications-yml input` |

The variables are checked as warnings, never errors (D5), on every event, so a pull request shows
them too, and not at all in a repository that set `enabled: false`:

| Mistake | Warning |
|---|---|
| a partial set | `notifications are off: TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are set together or not at all; missing: TF_NOTIFY_ALIAS` |
| a URL | `notifications are off: TF_NOTIFY_BOT_URL is 'http://…/api'; it must start with https:// and end with /api` (a trailing `/` is accepted) |
| an audience | `notifications are off: TF_NOTIFY_BOT_AUDIENCE is '…'; it must start with api://` |
| an alias | `notifications are off: TF_NOTIFY_ALIAS is 'TF Alerts'; an alias is 2 to 50 of a-z 0-9 -, starting and ending with a letter or a digit` |

Key names avoid what the metadata capture drops from the matrix and `github` contexts, without
regard to case: any key containing `auth`, `token`, `secret`, `credential` or `password`, ending in
`_key`, or named `key`.

## 7. The engine

`create-tf-vars-matrix` gains the input `notify-target-json`, the three variables as
`{"bot-url", "bot-audience", "alias"}` (an unset one `""` or `null`, empty for no target at all),
which reaches the engine as a file (`--notify-target-file`) and the input document as
`notify_target` (`bot_url`, `bot_audience`, `alias`). The engine validates §6.4, writes the resolved
`notifications-yml` into every row, and decides the output document's `notify` block, which
`relevance.json` carries too:

```json
{"active": true, "reason": "on",
 "target": {"bot-url": "https://…/api", "bot-audience": "api://…", "alias": "…"},
 "senders": {"prod": {"github-environment": "production",
                      "extra-envs": {"ARM_TENANT_ID": "…"},
                      "extra-envs-from-secrets": {"ARM_CLIENT_ID": "PROD_CLIENT_ID"}}}}
```

`active` is true for a `push`, `schedule` or `workflow_dispatch` on the default branch (a branch of
that name, never a tag) with a valid target and `enabled` not `false`. Otherwise `reason` says why:
`no target: TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are not set`,
`the target is incomplete`, `the target is invalid`,
`switched off: notifications-yml sets enabled: false`, or
`only a push, a schedule or a dispatch on the default branch notifies`. `target` is the checked
target whenever it is valid, also on a run that does not notify, and null otherwise. The step logs
the reason in a group of its own, `notifications`, and publishes two outputs: `notify-active`
(`"true"` or `"false"`) and `notify-target-json` (the target, or `{}`). A module decides no
notifications.

`senders` lists every environment of `environments-yml`, whether or not the run ran it, because
`deliver-as` may name one it did not: its `github-environment`, and the `ARM_TENANT_ID` and
`ARM_CLIENT_ID` entries of its resolved job-wide `extra-envs` and `extra-envs-from-secrets` (values
and secret names, never secret values). A deliver job hands exactly these to `export-env-vars` with
the secrets, so the identity resolves as the environment's own job resolves it (§12).

A command, `decide-notifications`, runs after the environments, as `evaluate-automerge` does
([Decision-engine.md](Decision-engine.md) §3.2), through the action
[`decide-notifications`](../decide-notifications/action.yml):

| Input | From |
|---|---|
| `--metadata-files-pattern` | a glob over the downloaded `matrix-job-meta-*.json` files |
| `--matrix-file` | `create-matrix`'s `matrix-json`: every relevant environment's row, held-back ones included |
| `--relevance-file` | the `relevance` artifact: the environments' stages, and `notify` (§7) with the target, the senders and the deliver jobs' runner |
| `--stage-results-file` | `stage-results-json`, as the auto-merge job builds it |
| `--state-file` | the state restored from the cache (§9); a file that does not exist means none |
| `--out-dir` | where it writes its files |
| the runner's environment | the event and its payload (the push's `before`, `after`, `forced` and sender, the default branch), the run's ID, number and attempt, the server URL, and `GH_TOKEN` for §5 |

The core first says which costly facts the run needs, and the adapter gathers only those: the
people of the push (§5) when a push opens or repeats an incident, and the protection rules of each
sender it posts as (`GET /repos/{owner}/{repo}/environments/{name}`: a rule other than a branch
policy holds a job; an environment that does not exist holds nothing). A run with nothing to send
asks GitHub nothing. Each fact that cannot be gathered is a fact: people that cannot be read make
the message say so, and a sender whose rules cannot be read is not used. A metadata file that
cannot be used, stage results that cannot be read and a stored state of another shape are
warnings; only the relevance file and the matrix are needed, and without them the step fails.

The result of an environment in the `apply` slot, from its metadata:

| The environment | Result |
|---|---|
| due to apply, its `apply` step `success` | applied |
| due to apply, its `apply` step `failure` or `cancelled` | failed or cancelled, at `apply` |
| due to apply, `apply` did not run | failed or cancelled at the first of `init`, `verify-lock`, `fmt`, `validate`, `lint`, `plan` that failed or was cancelled; failed when none says why |
| not due to apply, on a schedule or dispatch, its plan `success` and read whole: no change, no output-only change | clean |
| due to apply, no metadata, its stage `skipped` after an earlier stage failed or was cancelled | held back |
| due to apply, no metadata, its stage `failure` or `cancelled` | failed or cancelled, the job unreported |
| anything else | nothing; without metadata, unknown, and nothing is said |

The core writes:

| File or output | Holds |
|---|---|
| `events/<id>.json` | one event per message to post (below) |
| `events/<id>.md` | its rendered markdown text (§11) |
| `observations.json` | `run_number` and, per environment and slot, what this run saw and did, for the record job |
| `summary.md` | sent, not sent and why; also appended to the step summary |
| `deliver-matrix-json` | `{"include": [...]}`, one row per message: `id`, `sender`, its `github-environment`, the deliver job's `runs-on`, `alias`, `reply-to`, `update`, `idempotency-key`, and the sender's `extra-envs` and `extra-envs-from-secrets` (§7's `senders`) |
| `deliver-count` | the number of rows |

```json
{"id": "e1", "environment": "prod", "slot": "apply", "kind": "apply-failed",
 "action": "open", "alias": "tf-alerts", "reply_to": null, "update": null, "sender": "prod",
 "idempotency_key": "9f2c…", "message": "e1.md"}
```

`action` is `open`, `reply`, `resolve` or `removed` (§9). The idempotency key is the SHA-256, in
lowercase hex, of `<repository>/<run id>/<run attempt>/<environment>/<slot>/<action>`: one key per
message of a run attempt, so re-running only a deliver job posts nothing twice, and hashed because
the relay's store refuses `/` in a key and an environment name may be 255 characters. Mentions and
direct messages join the event when the relay supports them (§13). The rules are pure, under the
engine's coverage and mutation gates (`notify_decide.py`, `notify_state.py`); the adapter is
`notify_evidence.py`.

## 8. The workflow

`terraform-notify.yml` is `on: workflow_call` with the inputs `matrix-json`, `stage-results-json`,
`notify-target-json` and `runs-on`, and three jobs. Every job has job-level
`continue-on-error: true` and `timeout-minutes: 10`; structural test F32 holds each of them.

**`decide`**, `if: always()`, on `runs-on`,
`permissions: { actions: read, contents: read, pull-requests: read }`: downloads the metadata and
the relevance artifact as the auto-merge job does, restores the state (§9), runs
`decide-notifications` (the two JSON inputs read and written again with `toJSON(fromJSON(…))`, so
what its run block captures is JSON by construction, F9), and uploads `--out-dir` as the
`notify-events` artifact.

**`deliver`**, `if: always() && needs.decide.outputs.deliver-count != '' && … != '0'` (the count is
set only by a decide job that finished, and an empty matrix fails, P9), a matrix over the decide
job's rows with `fail-fast: false`, one job per message, on the row's `runs-on`,
`environment: { name: <row's github-environment>, deployment: false }`,
`permissions: { id-token: write }`:

1. Download `notify-events`.
2. Export the row's `extra-envs` and `extra-envs-from-secrets` with
   [`export-env-vars`](../export-env-vars/action.yml) and the secrets: the sender's
   `ARM_TENANT_ID` and `ARM_CLIENT_ID`, resolved as its own job resolves them, and nothing else.
3. Log in with `azure/login` and `allow-no-subscriptions: true`, immediately before posting: the
   GitHub assertion behind the login lives about five minutes (P5).
4. Post `events/<id>.md` with `post-teams-notification` (§11), to the row's alias, with its
   `reply-to`, `update` and idempotency key.
5. Write the relay's answer, `{id, accepted, message_id, http_status}`, and upload it as
   `notify-result-<id>`, whatever happened before.

**`record`**, `needs: [decide, deliver]`, `if: always() && needs.decide.outputs.deliver-count != ''`,
on `runs-on`, `permissions: {}`,
`concurrency: { group: tf-notify-state, cancel-in-progress: false, queue: max }` (a group otherwise
holds one waiting job and cancels the one before it): downloads the events and the answers, restores
the newest state under the lock, runs `record-notifications` through the action
[`record-notifications`](../record-notifications/action.yml), which merges the observations and the
answers into it (§9) and lists every delivery that was not accepted in the step summary, and saves the
state when it changed.

The default workflow calls it as one job:

```yaml
  notify:
    needs: [create-matrix, terraform-ci-cd, terraform-ci-cd-2, terraform-ci-cd-3]
    if: always() && needs.create-matrix.outputs.notify-active == 'true'
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-notify.yml@v1
    secrets: inherit
    permissions: { actions: read, contents: read, pull-requests: read, id-token: write }
    with:
      matrix-json: ${{ needs.create-matrix.outputs.matrix-json }}
      stage-results-json: '{"1": "${{ needs.terraform-ci-cd.result }}", "2": …, "3": …}'
      notify-target-json: ${{ needs.create-matrix.outputs.notify-target-json }}
      runs-on: ${{ inputs.runs-on }}
```

and `create-matrix` hands the engine the target from the variables:

```yaml
          notify-target-json: >-
            {"bot-url": ${{ toJSON(vars.TF_NOTIFY_BOT_URL) }}, "bot-audience": ${{ toJSON(vars.TF_NOTIFY_BOT_AUDIENCE) }}, "alias": ${{ toJSON(vars.TF_NOTIFY_ALIAS) }}}
```

`always()` and not `!cancelled()`: a cancelled run is exactly when `apply-cancelled` must go out.
`notify` waits for the stages only; it needs the tests and the conclusion once the run-level kinds
of D17 arrive. Structural test F31 holds `create-matrix`'s target and outputs, `notify`'s `needs`,
`if`, permissions and inputs, and that no job needs `notify`.

## 9. Incident state

One JSON document per repository, in the Actions cache under
`tf-notify-state-<run id>-<run attempt>`, restored by the prefix `tf-notify-state-`, which returns
the newest entry. Entries are immutable; a new one is saved only when the state changed. The path,
`.tf-notify-state` in the workspace, is the same in every job: it is part of an entry's version, and
an entry saved from another path is never restored.

```json
{"schema_version": 1,
 "incidents": {"prod/apply": {"kind": "apply-failed", "status": "open", "message_id": "msg-…",
   "alias": "tf-alerts", "sender": "prod", "opened_at": "2026-10-07T12:00:00Z", "opened_run": 412,
   "seen_run": 415, "people": ["jdoe", "asmith"], "resolved_at": null}}}
```

Keys are `<environment>/<slot>`, the environment lowercased. `status` is `open`, `pending` (the
relay did not accept the first message) or `resolved`. `alias` and `sender` are where the first
message went and who sent it: every later message of the incident goes there, as them, whatever the
routing says by then, because the relay refuses a reply to a message of another alias. `seen_run`
is the run number of the newest observation; the record job ignores an observation from an older
run, so a re-run of an old commit, or an earlier run finishing last, cannot reopen what a newer run
resolved. A resolved incident stays as a tombstone for 30 days, then is dropped; deleting a cache
entry would need `actions: write`, beyond the callers' grant. A stored document of another
`schema_version` is started over, never misread.

The decide job reads the newest state without the lock. Two overlapping runs can both see no open
incident and both post a new message: a duplicate thread, never a lost one, because the record job
merges under the lock and keeps the older `message_id`.

| Last state | This run | Action |
|---|---|---|
| none, resolved or pending | apply failed, cancelled or held back, on a push or a schedule | `open`: a new message; the incident is open once the relay accepts it, else pending |
| open | the same again, on a push | `reply`: a message in the thread, naming the push's people |
| open | the same again, on a schedule | nothing; the schedule's are the reminders (§10) |
| any | apply failed, cancelled or held back, on a dispatch | nothing (D8) |
| open | applied, or a clean plan on a schedule or dispatch | `resolve`: a message in the thread; a tombstone |
| pending | applied, or a clean plan | a tombstone, without a message: the incident never reached Teams |
| open or pending, for an environment no longer in `environments-yml` | any run | `removed`: "No longer watched", as the incident's sender; a tombstone. When the sender is gone too, the tombstone alone, said in the summary |
| open | not run | nothing |
| a kind with `off: true` | | opens nothing |

A state entry unused for seven days, or pushed out by the repository's 10 GB cache limit, is gone.
The next failure then opens a new thread, and the old message is never marked resolved: the cost of
keeping no state outside the cache.

**Without threads, as the relay is today.** Every `reply`, `resolve` and `removed` carries the first
message's `messageId` as `reply-to`; until the relay supports it (§13) it ignores the field and posts
in the channel. So every message stands alone: it names the environment and the repository, and a
reply or resolution says since when the environment has not been applied. No `update` is sent
before the relay supports it, because today it would be a second post; the incident's first message
is then updated to resolved as well.

## 10. Reminders

Not built yet. On a scheduled run, each open incident in the `apply` slot whose next reminder is due
gets a reply in its thread. Age counts in working days, Monday to Friday; the reply goes out with the
first scheduled run after the reminder is due. The state gains `reminder_level` and `reminded_at`.

| `reminder_level` | Due after | Reply mentions |
|---|---|---|
| 1 | one working day open | the people it opened with |
| 2 | three working days open | the same and the mergers, and the channel's team tag |
| 3 and on | five more working days each | the team tag |

A schedule that runs at night posts at night; the reminder is read in the morning. An environment
without a schedule gets no reminders; `remind: false` turns them off for a kind. Until the relay
mentions tags (§13), level 2 and on mention no tag. Drift reminders follow
[Drift-detection.md](Drift-detection.md) §5.

## 11. The relay client: `post-teams-notification`

A composite action in the modern layout
([Action-implementation-guide.md](Action-implementation-guide.md)). It posts; it decides nothing.

| Input | Meaning |
|---|---|
| `bot-url`, `bot-audience`, `alias` | the target; an alias outside the relay's own rule (2 to 50 of `a-z`, `0-9` and `-`, starting and ending with a letter or a digit) is not posted to |
| `message-file` | the rendered markdown text, posted as it is; an empty or unreadable file is not posted |
| `reply-to`, `update` | a `messageId`, sent as `replyTo` or `update`; the relay takes one or the other, so both together are not posted, and it ignores them until it supports them (§13) |
| `idempotency-key` | from the event, computed by the decide job, so re-running only the deliver job does not post twice; 1 to 256 printable characters without spaces |
| `dry-run` | print the URL and the request body; send nothing and ask for no token |

| Output | Meaning |
|---|---|
| `message-id` | the relay's `messageId` |
| `http-status` | the last response's status, `000` for none |
| `accepted` | `true` when the relay accepted the request; acceptance is not delivery (P4) |

It gets a token with `az account get-access-token --resource <bot-audience>` as the identity the job
is logged in with, posts `{"format": "text", "message": <the file>}` to
`<bot-url>/v1/notify/<alias>`, and never fails its step: anything not sent is a `::warning` titled
*Teams notification not sent*, naming the alias and why, and `accepted: false`. The token never
enters a variable or an argument; it goes from `az` to a header file in a private directory, and the
message stays in files too, out of reach of `allexport`
([Action-implementation-guide.md](Action-implementation-guide.md) → "Anti-pattern: exporting
heredoc-captured JSON").

Retries are bounded. Each request times out after 30 seconds. 429, 5xx and no answer are retried
at most three times, after `Retry-After` when it gives seconds, otherwise after 1, 2 and 4 seconds,
with the same idempotency key. A wait is taken only when it and the next request at its full
timeout still fit a 180-second budget, so the step ends within the budget whatever the relay does;
when it does not fit, the warning says the budget is spent. Any other 4xx is not retried, and its
warning carries the relay's problem detail, or for a bare 401 or 403 (the platform's own
authentication answers without a body) what to check: the audience, or the `Notifications.Send`
role. A `messageId` that is not a plain ID is not passed on.

Mentions and direct messages (D11) join as inputs once the relay supports them (§13).

The decide job renders the message (D23), paragraphs of markdown text:

```markdown
❌ **Apply failed** in `prod` · example-org/example-repo

The `apply` step failed, so the default branch is not applied in `prod`.

Change: [#7](https://github.com/example-org/example-repo/pull/7) `Add a storage account` by jdoe, merged by asmith.

[Open the run](https://github.com/example-org/example-repo/actions/runs/4711/attempts/1)
```

A first line that says what and where (`❌ Apply failed`, `🚫 Apply cancelled`, `⏸️ Held back`,
the same `again` for a reply, `✅ Applied`, `✅ No longer watched`), in which environment and
repository, why (the step that failed or was
cancelled, the stage that held it back, or that the job did not report), who (§5; on a schedule
"Found by the scheduled run."; "Who made the change could not be read." when the people are not
known), and the run. Links are built from numbers, never from text. Environment names and steps are
written as code; the repository is plain text, because Teams draws every code span as a box and an
`owner/name` is letters, digits, `.`, `-` and `_`, none of which starts markup inside a word; a login is
letters, digits and hyphens. A pull request's title, the one piece of
free text, is a code span with every `` ` `` made `'`, `<` and `>` made `‹` and `›` and whitespace
collapsed, cut to 100 characters: inside a code span nothing is markup, and nothing in it can end the
span, so a title can carry neither a link nor a mention, without relying on backslash escapes. At
most ten pull requests are listed, then "and N more", so a message stays far under the relay's 28 KB
request limit.

## 12. Identity and network

- The sending environment's identity is its job-wide `ARM_TENANT_ID` and `ARM_CLIENT_ID`: the values
  its resolved `extra-envs-yml` holds, or the secrets its `extra-envs-from-secrets-yml` names, read in
  the sender's GitHub Environment, as `create-matrix` lists them in `notify.senders` (§7). Per-goal
  values are not read. An environment whose sender
  has neither gets a warning in the summary instead of a delivery.
- Each sending identity holds the relay API's `Notifications.Send` application role, granted when
  its landing zone is onboarded (§14). The relay's API accepts tokens from its own tenant only; an
  environment in another tenant names a same-tenant sender with `deliver-as` (D16).
- `ubuntu-latest` reaches an instance whose `allowed_caller_rules` admit the hosted runners' egress,
  such as the `AzureCloud` service tag; the landing-zone module denies every other caller by default.
- `GITHUB_TOKEN` is enough for everything on the GitHub side (§5, §7, §9) except reading SAML
  identities, which needs the identity App (D21).

## 13. What the relay must offer

| Capability | Needed by | Today |
|---|---|---|
| Post markdown text to an alias, returning a `messageId` | §4 | yes |
| Reply to and update a message by its `messageId`, and report whether it was delivered | threads (§9) | no; Teams supports both, verified |
| Mentions by Entra object ID or UPN, each checked against the roster of the team being posted to, an unknown one sent as plain text | mentions (D11) | no; Teams mentions by object ID and UPN notify, verified |
| A direct message by Entra object ID or UPN, through the roster of a team the bot shares with the person | `direct` (§6.2) | no; verified through the roster |
| Mentions of a channel's tag | reminders (§10) | no |

Escalation, reminders, deduplication, digests, GitHub identities (D21), per-alias authorization
(D22) and `Action.OpenUrl` (D23) are not asked of the relay. One finding is passed on without being
a requirement: any Teams user who can message the bot can repoint or remove any alias with its
commands, which the relay's own documentation says is refused.

## 14. Onboarding a landing zone

1. A relay instance runs for the landing zone, with the hosted runners' egress (the `AzureCloud`
   service tag) in its `allowed_caller_rules`, and an alias created in a standard channel.
2. Each sending identity of the landing zone holds `Notifications.Send` on that instance's API.
3. The landing zone's repositories get `TF_NOTIFY_BOT_URL`, `TF_NOTIFY_BOT_AUDIENCE` and
   `TF_NOTIFY_ALIAS` as repository variables.
4. A repository whose production runs behind a protected GitHub Environment sets `deliver-as`.
5. For mentions, once per organisation: the identity App installed with Members read, and §6.1's
   three settings at organisation level.
6. Each repository on v1 notifies from its next push to the default branch.

## 15. What stays out

- Pull-request comments, GitHub issues, Jira tickets and e-mail (D1).
- A `workflow_run` listener file per repository: it cannot be on by default.
- Escalation or deduplication in the relay (D2).
- A notification when a run never started, or a schedule that stopped: nothing inside a run can
  report it. Absence detection belongs with Azure Monitor and the relay's existing alert route,
  per landing zone, outside this repository.

## 16. Compatibility

A repository without the three variables sees one skipped job and nothing else. With them, it starts
notifying on the next push to the default branch; `enabled: false` restores the previous behaviour.
A minor release.

## 17. Residual risks

| Risk | Mitigation |
|---|---|
| A channel nobody reads because it is noisy | Only unattended failures; one thread per incident; reminders in working days |
| A shared credential expiring fails every environment at once: one message each | Accepted for now; one message per channel per run listing the environments is a later rule in the decide job |
| A mention of the wrong person | The relay checks every mention against the team's roster before posting (P2) |
| Any repository of a landing zone able to post into any of its aliases | Accepted (D22): the posting identities can already change production |
| A delivery lost after the relay accepted it | Delivery status from the relay (§13) |
| A message that says failed about a success | The outcome comes from the steps, never from parsed counts |
| Text from a pull request in a bot's message | Rendered and escaped without secrets (D20, §11) |

## 18. Pitfalls

| # | Pitfall | Seen as | Answer |
|---|---|---|---|
| P1 | `workflow_run.pull_requests` is empty for push runs and can list other repositories' fork pull requests. | A wrong or missing author. | Not used; §5. |
| P2 | Teams drops a mention entity it cannot resolve and puts the next mention on the first `<at>` tag. | Seen on the relay's test instance: a nonexistent person shown as the real one. | The relay checks each mention against the roster first. |
| P3 | `deployment: false` does not bypass required reviewers, and cannot be combined with a custom deployment protection rule. | A deliver job waiting for an approval, or one that cannot start. | D16: protected senders are not used. |
| P4 | A 202 from the relay means queued, not delivered. | A message that never arrives, unreported. | `accepted`, not `delivered` (§11); delivery status (§13). |
| P5 | The GitHub OIDC assertion behind an Entra login expires after about five minutes; a later `get-access-token` fails. | `AADSTS700024` after a long job. | Log in immediately before posting. |
| P6 | The relay's `Idempotency-Key` is global across callers and never expires. | A recurring incident swallowed as a duplicate. | The key carries the repository, run, attempt and action (§7). |
| P7 | A bot cannot post into a private channel. | No message, no error from the API. | Aliases in standard channels only. |
| P8 | The metadata capture drops keys containing `auth`. | No author in the artifact. | §5. |
| P9 | A matrix job with an empty matrix fails ([Environment-ordering.md](Environment-ordering.md) P4). | A red `deliver` on every run with nothing to send. | The `deliver-count` guard. |
| P10 | Actions cache entries are immutable, and a prefix restore returns the newest entry of any run. | Lost updates between overlapping runs; a re-run that cannot save. | One document, keyed by run and attempt, merged under a lock (D19). |
| P11 | `GITHUB_TOKEN` cannot read an organisation's SAML identities; they are visible to owners and to an App installation token with Members read. | `samlIdentityProvider` is `null`. | The identity App (D21). |
| P12 | An identity's SAML `nameId` is the person's mail, which people can change themselves. | A mention that stops resolving after a rename. | The object ID from the attributes; the UPN only as display and filter. |

## 19. Tests

- **Engine:** the rules of §4, §5 and §9 as table cases, at 100 percent coverage and through the
  mutation gate (`test_notifications`, `test_notify_decide`, `test_notify_state`): every result of
  §7, every transition of §9, stale observations, pending posts, removed environments and their
  senders, overlapping runs, routing and `deliver-as`, protected and identity-less senders, every
  message as a literal; validation messages as literal strings; the adapter (`test_notify_evidence`)
  against files on disk and a stub `gh`, including missing and unreadable ones, the first-parent
  walk, bots by name and by type, and every failure of a GitHub call as a fact.
- **Actions:** `decide-notifications` and `record-notifications` run their action's run block end to
  end, with shell syntax in the pasted JSON and a caller's `json.py` in the working directory.
- **Action:** `post-teams-notification` against a fake relay (a local HTTP server answering a
  scripted list of responses and recording every request) and a stub `az`: the request's shape, 202
  with and without a `messageId`, 4xx with and without a problem detail, 429 with `Retry-After`, 5xx
  and no answer until the retries run out, the budget, no token, the token never printed, `dry-run`,
  and every input that is not posted.
- **Structural:** F31, `create-matrix`'s target and outputs, `notify`'s `needs`, `if`, permissions
  and inputs, and that no job needs it; F32, in `terraform-notify.yml` every job's `if`,
  `continue-on-error`, timeout and permissions, `deliver`'s `environment` with `deployment: false`,
  matrix, runner and identity export, and `record`'s queueing lock.
- **Test bed:** a test-bed repository on the default workflow's preview ref, its three variables
  pointing at the relay's test instance. One environment fails its apply while a switch is on,
  another depends on it, and a third, named by `deliver-as`, sends for both: its identity holds
  `Notifications.Send` and nothing else, and its client ID is an environment secret. Four runs on
  the default branch did what §9 says, and the relay accepted every post (202):
  1. a push whose apply failed and whose second stage was held back: two `open` messages, and the
     first state saved;
  2. the same failure pushed again: two `reply` messages, from the state the first run saved;
  3. a dispatch while it still failed: nothing sent, the state moved on;
  4. the recovery: two `resolve` messages.

  That settles three questions on a real run: environment secrets reach the nested deliver job, the
  nested job signs in with its environment's subject, and `GITHUB_TOKEN` reads an environment's
  protection rules. A cancelled apply and a protected sender were not run there; both are unit
  tested.

Teams behaviour verified against the relay's test instance, posting as its bot through the Bot
Framework API: mentions by object ID and by UPN render and notify in cards and text replies, and
survive an update; an unresolvable mention shifts the others (P2); replies to a message ID and
in-place updates work; a direct message through the team roster works.

## 20. Open questions

- Does an organisation's OIDC subject template that includes `job_workflow_ref` give the nested
  deliver job a subject the sending identity does not trust? The test bed's repository uses GitHub's
  default template, where the subject is `repo:<owner>/<repo>:environment:<name>`; an organisation
  with its own template needs a run.
- Does any Conditional Access policy restrict the sending identities' sign-ins from GitHub-hosted
  runners? None did for the test instance's landing zone; each other landing zone needs a run.
- Does an installation token with Members read only see `samlIdentityProvider` for an organisation
  with SAML at organisation level, as GitHub's schema says? Needs one query with the App.
- The relay capabilities of §13: specified for the relay's maintainers separately.

The preview refs need no change: the rewrite covers every internal `uses:` in every workflow file, a
nested one included ([Preview-refs.md](Preview-refs.md) §4.1). The test bed ran on the preview ref, the
nested workflow and its actions included.

## 21. Implementation order

1. The relay client action and its fake relay. Built.
2. The engine: validation, `notify-active`, `decide-notifications` with the kinds of §4 and the
   state of §9. Built.
3. `terraform-notify.yml` and the default workflow's `notify` job, built; the test bed.
4. Reminders (§10), with [Drift-detection.md](Drift-detection.md).
5. Threads in place, mentions and direct messages, as the relay offers them.
