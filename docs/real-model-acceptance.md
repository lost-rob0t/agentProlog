# Manual real-model product acceptance

Final product acceptance belongs to **lost-rob0t/agentProlog**. The repository
Actions secret name is **ZAI_API_KEY**, mapped only to the same environment
variable in the manual acceptance step. The user creates/manages that secret;
this implementation does not create, retrieve or print it. An attempted metadata
read was forbidden, so existing Actions-secret presence is unknown.

The workflow is `.github/workflows/live-agent-acceptance.yml`, titled
**Manual real-model agent acceptance**. It has only `workflow_dispatch`; pushes
and pull requests never call a model. Select the reviewed branch, supply its
exact commit in `reviewed_commit`, and confirm existing authorized subscription
access with sufficient quota. Missing authorization, wrong commit, missing
credential, unsupported runtime adapter or failed task produces failure, not a
passing skipped acceptance test.

GitHub requires a manual workflow to exist on the default branch before it can
be dispatched. This workflow is currently delivered in draft PR #51, so adding
the secret alone does not make it runnable. Registering the workflow requires a
separately reviewed bootstrap change on the default branch; do not merge the
unfinished product merely to enable acceptance. After registration, select the
reviewed feature branch and its exact commit. See
[GitHub's manual workflow requirements](https://docs.github.com/actions/managing-workflow-runs/manually-running-a-workflow).

The model is `glm-5.3-flash`. The trusted acceptance profile calls upstream
`zai_coding_provider(chat_completions, 'glm-5.3-flash', Provider)`, which uses
`https://api.z.ai/api/coding/paas/v4/chat/completions` and
`credential(env('ZAI_API_KEY'))`. There is no standard/pay-as-you-go endpoint
fallback and no replacement provider implementation in AgentProlog. The user
must use the intended existing subscription credential type; an endpoint URL
alone is not a guarantee of billing category. No new account, credential,
purchase or persistent access grant is created by this test.

The coordinated runtime candidate exports the constructor. The workflow also
checks that export before the credential-bearing step.
Until native approval continuation is ready,
this gate cannot establish final acceptance. No real-model run has passed yet.

The task runs in a newly created temporary workspace containing only a synthetic
input. The actual model must read it, create a file, modify it, overwrite it and
read back the final bytes using the real generic workspace tools and native
context inspection. The test approves only operations from that trusted,
capability-limited fixture registry. It asserts the actual final file bytes and
all required tool results. No OSINT, external files or deployment is involved.

Bounds: 12 model calls, 12 registered tool calls, 16 iterations, 12,000 total
tokens, 64 KiB output, 120-second native budget and 150-second outer limit.
The USD 0.10 runtime budget is an additional guard, not a guarantee that all
providers supply billing data; the run requires existing authorized quota and
must not initiate unapproved pay-as-you-go spending.

Evidence contains the exact application/runtime commits, observed provider/model
(null when runtime metadata is unavailable),
latency, available numeric token/cost fields, approval count, tool names and
verified final bytes. Raw provider diagnostics, prompts, response bodies and
credentials are not uploaded. Absence of cost information must remain unknown,
not be reported as zero. Local deterministic and hosted synthetic tests remain
separate evidence and cannot replace this gate.
