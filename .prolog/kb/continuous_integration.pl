ci_runtime_repository(github, 'lost-rob0t/prolog-rlm').
ci_runtime_repository(forgejo, 'nsaspy/prolog-rlm').
ci_runtime_revision_source('flake.nix', exact_sha).
ci_failure(runtime_checkout_wrong_owner, repository_not_found).
ci_failure_source(runtime_checkout_wrong_owner,
    'https://git.starintel.actor/nsaspy/agentProlog/actions/runs/59/jobs/1').
ci_runtime_checkout_constraint(actions_checkout, repository_resolves_on_current_forge).
ci_installer_action(forgejo,
    'https://github.com/DeterminateSystems/nix-installer-action@main').
ci_workflow(forgejo, '.forgejo/workflows/ci.yml', full_offline_and_nix_gate).
ci_workflow(github, '.github/workflows/', separate_github_jobs).
ci_merge_constraint(exact_head, all_automatic_jobs_success_not_missing_or_skipped).
