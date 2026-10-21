# {{PROJECT_NAME}} AI Collaboration Guide

The workflow manager created this repository instruction entry because the
project did not already provide `AGENTS.md`. Keep it in Git with the other
workflow definitions so every device receives the same collaboration contract.

## Required Context

- Read this file and `WORKFLOW.md` before changing the project.
- Read the closest module documentation and instruction files for every changed
  area, then inspect direct callers and state sources.
- Follow existing project architecture and dependencies; keep changes focused.

## Task Contract

Before editing, state `Route`, `Why`, `Context`, and `Validation Harness` as
defined in `WORKFLOW.md`. Routes may upgrade but may not downgrade.

## Code Comments

Follow the code-comment contract in `WORKFLOW.md` for newly added or modified
code. Every newly added or modified type member property and every method
requires a concise documentation comment, even when the declaration is
self-explanatory or the method is simple. Use Chinese by default unless the user
or repository instructions explicitly require another language. Do not narrate
implementation code line by line.

## Specification And Method

- Quick work does not require an OpenSpec change.
- Standard work uses OpenSpec when behavior or acceptance criteria are unclear.
- Spec work requires an OpenSpec change with proposal, requirements, design,
  and tasks approved before implementation.
- OpenSpec owns persistent requirements, design, and task artifacts.
- Superpowers supplies the applicable working method, such as brainstorming,
  test-driven development, systematic debugging, review, and verification.
- Do not create a second Superpowers plan when OpenSpec tasks are already the
  canonical implementation plan.

## Completion

Run the final harness and `./Scripts/ai-workflow validate --route <route>` with
the selected route and its required evidence. Report reproducible PASS, FAIL,
WARN, UNVERIFIED, and SKIP evidence. Never claim that a Hook, reviewer
acknowledgement, or written expectation substituted for a check.
