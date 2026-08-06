# ADR 0001: Engineering Standard

## Status

Accepted

## Decision

Use a BHT engineering standard influenced by:

- Google-style small changes, readability, documentation, and review discipline
- GitHub-native governance and security automation
- Microsoft Azure security and deployment practices
- Amazon-style operational readiness when production operations begin

## Consequences

Every feature must include appropriate tests, documentation, security analysis, and visual explanation. CI failure blocks merge. Direct pushes to `main` are prohibited once repository rules are configured.
