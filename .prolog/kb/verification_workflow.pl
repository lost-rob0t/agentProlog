:- module(verification_workflow, [suite_prerequisite/2]).

% A fresh checkout needs the locked install and package build before the TUI
% tests can resolve the agentprolog workspace package's compiled entry point.
suite_prerequisite(tui_tests, frozen_pnpm_install).
suite_prerequisite(tui_tests, agentprolog_package_build).
