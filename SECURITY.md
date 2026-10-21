# Security Policy

Airy deletes files, so a security bug can cost someone their data. Please report privately; **don't
open a public issue**.

## How to report

Use **[Report a vulnerability](https://github.com/luis-guillen/airy/security/advisories/new)**, GitHub's
private vulnerability reporting. Include:

- the Airy and macOS versions;
- steps to reproduce, without personal data;
- what you expected to happen and what actually happened.

You'll get an answer within 7 days. Fixes ship in a patch release, with credit to you if you want it.

## Supported versions

| Version | Supported |
|---|---|
| Latest release | ✅ |
| Older releases | ❌ |

## Scope

**In scope:** any path by which Airy, its detection sources, the catalog, the AI or an MCP agent could
do one of these:

- mark as safe, move to the Trash or delete something the hard protections forbid;
- skip the confirmation step;
- run a command outside the closed catalog;
- send file contents anywhere.

**Out of scope:** a user who deliberately confirms deleting their own files.
