# Architecture Decision Records

This directory contains Architecture Decision Records (ADRs) for Nopea.

ADRs document significant architectural decisions using the [Michael Nygard format](https://cognitect.com/blog/2011/11/15/documenting-architecture-decisions).

## Index

| ADR | Title | Status | Summary |
|-----|-------|--------|---------|
| [0001](0001-assessment-refactoring-decisions.md) | Assessment Refactoring Decisions | Proposed | Value objects, sync extraction, consolidation based on DDD/QA/Refactoring assessment |
| [0002](0002-ai-native-gitops.md) | AI-Native GitOps | Proposed | MCP server, history tracking, rollback, query API for AI assistants |

## Status Definitions

- **Proposed**: Under discussion, not yet accepted
- **Accepted**: Decision made, implementation can proceed
- **Deprecated**: No longer relevant
- **Superseded**: Replaced by another ADR

## Creating New ADRs

```bash
# Format: NNNN-title-with-dashes.md
touch docs/adr/0003-my-new-decision.md
```

Template:
```markdown
# ADR-NNNN: Title

## Status
Proposed

## Context
What is the issue that we're seeing that is motivating this decision?

## Decision
What is the change that we're proposing and/or doing?

## Consequences
What becomes easier or more difficult because of this change?
```
