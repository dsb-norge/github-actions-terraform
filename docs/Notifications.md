# Notifications

Authoritative spec for Microsoft Teams notifications from
[`terraform-ci-cd-default.yml`](../.github/workflows/terraform-ci-cd-default.yml): when an
environment on the default branch is left unapplied with nobody watching (an apply that failed after
a merge, a stage held back, a cancelled run), a card reaches the right Teams channel and names, and
later mentions, the people whose change it was.

Status: **specified, not built.** Teams-side behaviour this spec relies on was verified against a
deployed instance of the relay (§19); the open questions are in §20.
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
| D11 | A person is **named** in the card from the first kind on; **mentioned**, and for some kinds **messaged directly**, once the relay mentions and messages by Entra object ID (§13). | The relay knows Teams; this repository knows GitHub (D21). |
| D12 | One Teams thread per incident, addressed by the **`messageId` the relay returns** for its first post. The record job remembers it once the relay accepted the post, and the state forgets it when the incident resolves. | Unique per post, so a new incident never lands in an old thread; general for every relay caller; no caller-chosen keys in the relay. |
| D13 | Reminders come from the next scheduled run, never from the relay (§10). | D2. An unrelated push does not retry a failed apply ([Path-relevance.md](Path-relevance.md) P16), so a scheduled run is the only clock this repository has. |
| D14 | The deliver job runs on `ubuntu-latest`; `notifications-yml` may set `runs-on`. | Decided by the maintainer: a relay instance that admits the hosted runners' egress (the `AzureCloud` service tag in its `allowed_caller_rules`) needs no firewall work per landing zone, and the token with the relay's application role is the gate. The override covers an instance that does not. |
| D15 | A notification never changes a run's conclusion: the `notify` job is outside `conclusion.needs`, every job in `terraform-notify.yml` has job-level `continue-on-error`, a timeout and `if: always()`, and the deliver matrix is guarded against being empty. | The conclusion is a required check; an outage of the relay must not block merges. Step-level `continue-on-error` does not cover a job that cannot start. |
| D16 | **`deliver-as`** names the environment whose GitHub Environment and identity send for an environment; by default the environment itself. Set it repository-wide or per environment. A sender whose GitHub Environment has protection rules (reviewers, a wait timer, a custom rule) is not used: its events are reported in the run summary with a warning naming `deliver-as`. | A protected environment would hold the deliver job for approval ([Terraform-tests.md](Terraform-tests.md) P29), or with a custom rule never start it (P27), and the user guide puts production behind reviewers ([Workflow-terraform-ci-default.md](Workflow-terraform-ci-default.md) example 2). An environment whose identity lives in another tenant than the relay names a same-tenant sender the same way. Decided by the maintainer: no further machinery for other tenants. |
| D17 | Events of the run rather than of an environment (tests failing on the default branch, a configuration rejected, an auto-merge that failed) are out of scope at first. When they join, they deliver from the first environment that ran; a rejected configuration, where nothing ran, stays in the run's annotations and the conclusion line. | Rare on the default branch: the same validation and tests run on the pull request first. |
| D18 | GitHub admin and system accounts are never mentioned or messaged. | Decided by the maintainer: those accounts carry no Microsoft 365 licence and do configuration work, not changes to infrastructure. |
| D19 | The state of open incidents is **one document per repository** in the Actions cache, merged by the record job under a concurrency lock; an observation older than the stored one is ignored (§9). | Runs overlap and finish out of order (a later run's first stage can finish before an earlier run's last), and cache entries are immutable; one document merged under a lock loses nothing, and a stale run cannot reopen an incident a newer one resolved. |
| D20 | The card is rendered and escaped in the decide job, which holds no identity that can change anything; the deliver job posts the rendered bytes and exports nothing but the sender's tenant and client ID. | The deliver job holds an apply identity; nothing from a pull request should run or be interpreted there. |
| D21 | **GitHub logins are resolved here, not in the relay.** The decide job reads each named person's SAML identity in the organisation with an installation token of a GitHub App that holds organisation Members read and nothing else, and hands the relay Entra object IDs. Without the App, cards name people and mention nobody. | Decided by the maintainer: the relay stays free of GitHub knowledge and accepts Teams identities only. `GITHUB_TOKEN` cannot read SAML identities; an installation token with Members read can. Every member's identity carries the Entra object ID (`…/claims/objectidentifier`), which survives renames, and the UPN. |
| D22 | The relay is trusted on authentication: holding its `Notifications.Send` role is the whole permission to post, to any alias of that instance. | Decided by the maintainer: each landing zone has its own instance, and only its identities hold the role there, so one landing zone cannot post into another's channels; inside one, the posting identities are apply identities that can already change production. |

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

| The environment's result | Kind | Card says |
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

`mention` in §6.2 chooses which of those are mentioned once the relay can; the card always names
them. For each person to mention or message, the adapter reads the organisation's SAML identity of
the login with the identity App's token (D21):

```graphql
organization(login: $org) { samlIdentityProvider { externalIdentities(login: $login, first: 1) {
  nodes { samlIdentity { username givenName familyName attributes { name value } } } } } }
```

and takes the object ID from the attribute `http://schemas.microsoft.com/identity/claims/objectidentifier`,
the UPN from `username` and the display name from the given and family names. A login without an
identity, or whose UPN is not in `TF_NOTIFY_PEOPLE_DOMAINS`, is named and never mentioned: that is
how admin and system accounts, which live in another domain, stay out (D18). A failed lookup is a
fact like any other: the card names the person and mentions nobody. The environment jobs' metadata cannot supply any of this: it drops every key containing
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

Mentions and direct messages need three more organisation settings; without them cards name people
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
    drift:
      alias: tf-drift       # another channel on the same relay instance
    pending-change:
      off: true
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

### 6.3 Per environment

An `environments-yml` entry may carry `notifications-yml` with every key but `enabled` and
`runs-on`, the name every merged setting has per environment
([Configuration-validation.md](Configuration-validation.md) §3.1). It merges over the global value
key by key, so `kinds.drift.alias` per environment changes that and nothing else. In the engine,
`notifications-yml` is a `MERGE_FIELDS` setting with its own validation; like every one, its
resolved value is written into each environment's matrix row (`matrix.vars.notifications-yml`),
where the decide job reads it, held-back environments included. Every port golden gains the field.

### 6.4 Validation

`create-matrix` validates `notifications-yml` before any environment runs
([Configuration-validation.md](Configuration-validation.md)); a mistake fails the run on every event,
so it is found on the pull request that makes it.

| Mistake | Message |
|---|---|
| an unknown key | `notifications-yml: unknown key 'alias'; known keys: defaults, deliver-as, enabled, kinds, runs-on` |
| an unknown kind | `notifications-yml: kinds: unknown kind 'apply-fail'; kinds: apply-cancelled, apply-failed, held-back, …` |
| an unknown person | `notifications-yml: kinds.drift.mention takes author and merger, not 'owner'` |
| `deliver-as` naming no environment | `notifications-yml: deliver-as names 'dve', which is not an environment of environments-yml` |
| `enabled` or `runs-on` per environment | `environments-yml: environment 'prod': notifications-yml: 'enabled' is workflow-wide; set it in the notifications-yml input` |

The variables are checked as warnings, never errors (D5): a partial set (`notifications are off:
TF_NOTIFY_BOT_URL, TF_NOTIFY_BOT_AUDIENCE and TF_NOTIFY_ALIAS are set together or not at all;
missing: TF_NOTIFY_ALIAS`), a URL not starting `https://` or not ending `/api`, an audience not
starting `api://`. A kind that cannot fire in the repository (a drift kind with no environment on a
schedule) is one warning per kind. Key names avoid what the metadata capture drops from the matrix
and `github` contexts, without regard to case: any key containing `auth`, `token`, `secret`,
`credential` or `password`, ending in `_key`, or named `key`.

## 7. The engine

`create-matrix` gains the `notify-target-json` input, the validation of §6.4, the resolved
`notifications-yml` in every row, and two outputs: `notify-active`, `"true"` when the event is
`push`, `schedule` or `workflow_dispatch` on the default branch, the three variables are set and
valid and `enabled` is not `false`; and `notify-target-json`, the checked target.

A new command, `decide-notifications`, runs after the environments, as `evaluate-automerge` does
([Decision-engine.md](Decision-engine.md) §3.2):

| Input | From |
|---|---|
| `--metadata-files-pattern` | a glob over the downloaded `matrix-job-meta-*.json` files |
| `--matrix-file` | `create-matrix`'s `matrix-json`: every relevant environment's row, held-back ones included |
| `--relevance-file` | the `relevance` artifact |
| `--stage-results-file` | `stage-results-json`, as the auto-merge job builds it |
| `--state-file` | the state restored from the cache (§9); absent means none |
| `--out-dir` | where it writes its files |
| the runner's environment | the event, the default branch, the run's ID, number and attempt, `GITHUB_TOKEN` for §5 |

The adapter gathers the pull requests and identities of §5 and the protection rules of each sending
environment (`GET /repos/{owner}/{repo}/environments/{name}`); each is a fact, and a failure to
gather one is reported, never fatal. The pure core decides; it writes:

| File or output | Holds |
|---|---|
| `events/<id>.json` | one event per card to post (below) |
| `events/<id>.card.json` | its rendered Adaptive Card |
| `observations.json` | what this run saw, per environment and slot, for the record job |
| `summary.md` | sent, skipped and why, for the step summary |
| `deliver-matrix-json` | one row per sending environment: its `github-environment`, its tenant and client ID settings, and its event IDs |
| `deliver-count` | the number of rows |

```json
{"id": "e1", "environment": "prod", "slot": "apply", "kind": "apply-failed",
 "action": "open", "reply_to": null, "update": null,
 "mentions": [{"object_id": "…", "name": "…"}], "direct": [],
 "alias": "…", "idempotency_key": "<repository>/<run id>/<run attempt>/prod/apply/open",
 "card": "e1.card.json"}
```

`action` is `open`, `reply`, `resolve` or `remind`. The rules are pure, under the engine's coverage
and mutation gates; this takes the engine past deciding before the run, as `evaluate-automerge`
already did.

## 8. The workflow

`terraform-notify.yml` is `on: workflow_call` with the inputs `matrix-json`, `stage-results-json`,
`notify-target-json` and `runs-on`, and three jobs. Every job has `if: always()` (plus its guard),
job-level `continue-on-error: true` and a short `timeout-minutes`.

**`decide`**, on `runs-on`, `permissions: { actions: read, contents: read, pull-requests: read }`:
mints the identity App's installation token when §6.1's settings are present (with
`actions/create-github-app-token`, `permission-members: read`), downloads the artifacts as the
auto-merge job does, restores the state (§9), runs
`decide-notifications`, uploads the events as the `notify-events` artifact and writes `summary.md`
to the step summary.

**`deliver`**, `if: needs.decide.outputs.deliver-count != '0'`, a matrix over the decide job's rows,
on the `runs-on` of §6.2, `environment: { name: <row's github-environment>, deployment: false }`,
`permissions: { id-token: write }`:

1. Export `ARM_TENANT_ID` and `ARM_CLIENT_ID` from the row's settings with
   [`export-env-vars`](../export-env-vars/action.yml), and nothing else.
2. Log in with `azure/login` and `allow-no-subscriptions: true`, immediately before posting: the
   GitHub assertion behind the login lives about five minutes (P5).
3. Post each of the row's events with `post-teams-notification` (§11), and upload the results
   (`message-id`, `http-status`, `accepted` per event) as `notify-results-<row>`.

**`record`**, `needs: [decide, deliver]`, on `runs-on`, no permissions beyond reading artifacts,
`concurrency: { group: tf-notify-state, cancel-in-progress: false, queue: max }`: merges the
observations and the delivery results into the newest state and saves it (§9), and appends delivery
failures to the step summary.

The default workflow calls it as one job:

```yaml
  notify:
    needs: [create-matrix, terraform-ci-cd, terraform-ci-cd-2, terraform-ci-cd-3]
    if: always() && needs.create-matrix.outputs.notify-active == 'true'
    uses: dsb-norge/github-actions-terraform/.github/workflows/terraform-notify.yml@v1
    secrets: inherit
    with:
      matrix-json: ${{ needs.create-matrix.outputs.matrix-json }}
      stage-results-json: …       # built as the auto-merge job builds it
      notify-target-json: ${{ needs.create-matrix.outputs.notify-target-json }}
      runs-on: ${{ inputs.runs-on }}
```

`always()` and not `!cancelled()`: a cancelled run is exactly when `apply-cancelled` must go out.
`notify` waits for the stages only; it needs the tests and the conclusion once the run-level kinds
of D17 arrive. A new structural test holds `notify`'s `needs` and `if`, keeps it out of
`conclusion.needs`, and holds the three jobs' `if`, `continue-on-error` and `deployment: false`.

## 9. Incident state

One JSON document per repository, in the Actions cache under
`tf-notify-state-<run id>-<run attempt>`, restored by the prefix `tf-notify-state-`, which returns
the newest entry. Entries are immutable; a new one is saved only when the state changed.

```json
{"schema_version": 1,
 "incidents": {"prod/apply": {"kind": "apply-failed", "status": "open", "message_id": "msg-…",
   "opened_at": "…", "opened_run": 412, "seen_run": 415, "people": ["jdoe", "asmith"],
   "reminder_level": 0, "reminded_at": null}}}
```

Keys are `<environment>/<slot>`, the environment lowercased. `seen_run` is the run number of the
newest observation; the record job ignores an observation from an older run, so a re-run of an old
commit, or an earlier run finishing last, cannot reopen what a newer run resolved. A resolved
incident stays as a tombstone (`status: resolved`) for 30 days, then is dropped; deleting a cache
entry would need `actions: write`, beyond the callers' grant.

The decide job reads the newest state without the lock. Two overlapping runs can both see no open
incident and both post a new card: a duplicate thread, never a lost one, because the record job
merges under the lock and keeps the older `message_id`. An incident whose post the relay did not
accept stays `pending` and is posted fresh by the next run that sees it.

| Last state | This run | Action |
|---|---|---|
| none or resolved | apply failed, cancelled or held back | post a new card; record its `messageId` |
| open | the same, again | reply in the thread with the new run |
| open | resolved (§4) | update the card to resolved, reply "Recovered", tombstone it |
| open | not run | nothing |
| open, for an environment no longer in `environments-yml` | any run | update the card to resolved, reply "removed from the configuration", tombstone it |
| pending | the same, again | post a new card |

A state entry unused for seven days, or pushed out by the repository's 10 GB cache limit, is gone.
The next failure then opens a new thread, and the old card is never marked resolved: the cost of
keeping no state outside the cache.

**First release without threads.** Until the relay can reply to and update a message by its
`messageId` (§13), `reply` and `resolve` are new posts in the channel, quoting the incident's first
card time, and nothing is updated in place. Everything else, the state included, is as above.

## 10. Reminders

On a scheduled run, each open incident in the `apply` slot whose next reminder is due gets a reply
in its thread. Age counts in working days, Monday to Friday; the reply goes out with the first
scheduled run after the reminder is due.

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
| `bot-url`, `bot-audience`, `alias` | the target |
| `card-file` | the rendered Adaptive Card |
| `reply-to`, `update` | a `messageId`, once the relay supports them |
| `mentions`, `direct` | Entra object IDs with display names, once the relay supports them |
| `idempotency-key` | from the event, computed by the decide job, so re-running only the deliver job does not post twice |
| `dry-run` | print the request and send nothing |

| Output | Meaning |
|---|---|
| `message-id` | the relay's `messageId` |
| `http-status` | the last response's status, `000` for none |
| `accepted` | `true` when the relay accepted the request; acceptance is not delivery (P4) |

It gets a token with `az account get-access-token --resource <bot-audience>`, posts to
`<bot-url>/v1/notify/<alias>` with `format: adaptive-card` and the card as a file, and never fails
its step. Retries are bounded: each request times out after 30 seconds, 429 and 5xx are retried at
most three times with jitter, `Retry-After` is honoured only within what is left of a 3-minute
budget per card, and when the budget is spent the action reports `accepted: false` and moves on.
The deliver job's `timeout-minutes` is the hard stop above that. Its suite runs against a fake
relay that answers 202, 4xx, 429, 5xx and timeouts.

The decide job renders the card: a title, the environment, the facts (the step that failed, plan
counts, the stage held back on), the people (§5), and markdown links to the run and the pull request
built from their numbers, never from text. Text from a pull request or a commit (titles, branch
names, logins) has `\` `` ` `` `*` `_` `[` `]` `(` `)` `#` `+` `-` `.` `!` `|` `<` `>` and `~`
escaped and newlines replaced by spaces, so it can carry neither a link nor a mention. A card stays
under the relay's 28 KB request limit by shortening lists.

## 12. Identity and network

- The sending environment's identity is its job-wide `ARM_TENANT_ID` and `ARM_CLIENT_ID`: the values
  its matrix row's `extra-envs-yml` holds, or the secrets its `extra-envs-from-secrets-yml` names,
  read in the sender's GitHub Environment. Per-goal values are not read. An environment whose sender
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
| Post an Adaptive Card to an alias, returning a `messageId` | §4 | yes |
| Reply to and update a message by its `messageId`, and report whether it was delivered | threads (§9) | no; Teams supports both, verified |
| Mentions by Entra object ID or UPN, each checked against the roster of the team being posted to, an unknown one sent as plain text | mentions (D11) | no; Teams mentions by object ID and UPN notify, verified |
| A direct message by Entra object ID or UPN, through the roster of a team the bot shares with the person | `direct` (§6.2) | no; verified through the roster |
| Mentions of a channel's tag | reminders (§10) | no |
| `Action.OpenUrl` to an allow-listed host | link buttons | rejected today |

Escalation, reminders, deduplication, digests, GitHub identities (D21) and per-alias authorization
(D22) are not asked of the relay. One finding is passed on without being a requirement: any Teams
user who can message the bot can repoint or remove any alias with its commands, which the relay's
own documentation says is refused.

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
| A shared credential expiring fails every environment at once: one card each | Accepted for now; a card per channel per run listing the environments is a later rule in the decide job |
| A mention of the wrong person | The relay checks every mention against the team's roster before posting (P2) |
| Any repository of a landing zone able to post into any of its aliases | Accepted (D22): the posting identities can already change production |
| A delivery lost after the relay accepted it | Delivery status from the relay (§13) |
| A card that says failed about a success | The outcome comes from the steps, never from parsed counts |
| Text from a pull request in a bot's card | Rendered and escaped without secrets (D20, §11) |

## 18. Pitfalls

| # | Pitfall | Seen as | Answer |
|---|---|---|---|
| P1 | `workflow_run.pull_requests` is empty for push runs and can list other repositories' fork pull requests. | A wrong or missing author. | Not used; §5. |
| P2 | Teams drops a mention entity it cannot resolve and puts the next mention on the first `<at>` tag. | Seen on the relay's test instance: a nonexistent person shown as the real one. | The relay checks each mention against the roster first. |
| P3 | `deployment: false` does not bypass required reviewers, and cannot be combined with a custom deployment protection rule. | A deliver job waiting for an approval, or one that cannot start. | D16: protected senders are not used. |
| P4 | A 202 from the relay means queued, not delivered. | A card that never arrives, unreported. | `accepted`, not `delivered` (§11); delivery status (§13). |
| P5 | The GitHub OIDC assertion behind an Entra login expires after about five minutes; a later `get-access-token` fails. | `AADSTS700024` after a long job. | Log in immediately before posting. |
| P6 | The relay's `Idempotency-Key` is global across callers and never expires. | A recurring incident swallowed as a duplicate. | The key carries the repository, run, attempt and action (§7). |
| P7 | A bot cannot post into a private channel. | No card, no error from the API. | Aliases in standard channels only. |
| P8 | The metadata capture drops keys containing `auth`. | No author in the artifact. | §5. |
| P9 | A matrix job with an empty matrix fails ([Environment-ordering.md](Environment-ordering.md) P4). | A red `deliver` on every run with nothing to send. | The `deliver-count` guard. |
| P10 | Actions cache entries are immutable, and a prefix restore returns the newest entry of any run. | Lost updates between overlapping runs; a re-run that cannot save. | One document, keyed by run and attempt, merged under a lock (D19). |
| P11 | `GITHUB_TOKEN` cannot read an organisation's SAML identities; they are visible to owners and to an App installation token with Members read. | `samlIdentityProvider` is `null`. | The identity App (D21). |
| P12 | An identity's SAML `nameId` is the person's mail, which people can change themselves. | A mention that stops resolving after a rename. | The object ID from the attributes; the UPN only as display and filter. |

## 19. Tests

- **Engine:** the rules of §4, §5, §9 and §10 as table cases, at 100 percent coverage and through
  the mutation gate: every row of §4's table, stale observations, pending posts, removed
  environments, overlapping runs; validation messages as literal strings; the evidence adapter
  against recorded artifacts, including missing and unreadable ones; the escaping of §11.
- **Action:** `post-teams-notification` against the fake relay: every status, retries, `dry-run`,
  idempotency keys.
- **Structural:** `notify`'s `needs` and `if`, its absence from `conclusion.needs`, and in
  `terraform-notify.yml` every job's `if`, `continue-on-error` and timeout, `deliver`'s
  `environment` with `deployment: false`, and `record`'s concurrency group.
- **Test bed:** a test-bed repository with the three variables pointing at a test relay instance,
  a sending identity holding `Notifications.Send`, a protected environment using `deliver-as`, and a
  failing apply, a cancelled apply, a held-back stage, a recovery and a dispatch that resolves.

Teams behaviour verified against the relay's test instance, posting as its bot through the Bot
Framework API: mentions by object ID and by UPN render and notify in cards and text replies, and
survive an update; an unresolvable mention shifts the others (P2); replies to a message ID and
in-place updates work; a direct message through the team roster works.

## 20. Open questions

- Do environment secrets reach the nested `deliver` job with `secrets: inherit` on the `notify` job
  ([Terraform-tests.md](Terraform-tests.md) P26)? Needs a test-bed run.
- Can `GITHUB_TOKEN` read an environment's `protection_rules` (§7)? GitHub documents the call for
  anyone with read access. Needs a test-bed run.
- Does an organisation's OIDC subject template that includes `job_workflow_ref` give the nested
  deliver job a subject the sending identity does not trust? Needs a test-bed run per organisation.
- Does any Conditional Access policy restrict the sending identities' sign-ins from GitHub-hosted
  runners? Needs a test-bed run per landing zone.
- Does an installation token with Members read only see `samlIdentityProvider` for an organisation
  with SAML at organisation level, as GitHub's schema says? Needs one query with the App.
- The relay capabilities of §13: specified for the relay's maintainers separately.

The preview refs need no change: the rewrite covers every internal `uses:` in every workflow file, a
nested one included ([Preview-refs.md](Preview-refs.md) §4.1); the first preview run confirms it.

## 21. Implementation order

1. The relay client action and its fake relay.
2. The engine: validation, `notify-active`, `decide-notifications` with the kinds of §4 and the
   state of §9.
3. `terraform-notify.yml` and the default workflow's `notify` job; the test bed.
4. Reminders (§10), with [Drift-detection.md](Drift-detection.md).
5. Threads in place, mentions and direct messages, as the relay offers them.
