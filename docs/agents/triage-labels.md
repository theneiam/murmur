# Triage roles

No mapping of the five engineering-skill triage roles to existing GitHub
labels has been verified. The issue forms reference `bug` and `enhancement`,
which classify issue type; they do not establish triage states. Setup did not
create labels or assume GitHub's default labels are present.

| Canonical role | GitHub label | Local meaning |
|---|---|---|
| `needs-triage` | Unconfigured | Maintainer must evaluate the request. |
| `needs-info` | Unconfigured | Waiting for evidence from the reporter. |
| `ready-for-agent` | Unconfigured | Scope and acceptance criteria are sufficient for implementation. |
| `ready-for-human` | Unconfigured | Requires a human decision or hardware/manual action. |
| `wontfix` | Unconfigured | Not accepted for implementation. |

For this review, use the explicit status and acceptance criteria in
[ROADMAP.md](../ROADMAP.md); do not translate them into unverified GitHub
labels. Before an authorized future GitHub triage operation, inspect existing
labels, agree a mapping with the maintainer if needed, and update this file.
Missing labels do not authorize automatic creation.
