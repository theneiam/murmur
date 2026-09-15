# Domain documentation

Murmur is a single-context Swift/macOS application. There is no root
`CONTEXT.md` or `CONTEXT-MAP.md` at setup time. Read
[AGENTS.md](../../AGENTS.md), the single [architecture map](../ARCHITECTURE.md)
and [CLAUDE.md](../../CLAUDE.md) before exploring relevant code. Read dated
[decision records](../adr/) for the area being changed. Larger feature
designs live under [docs/superpowers/specs/](../superpowers/specs/).

If `CONTEXT.md` is introduced later, use it as the domain glossary; do not
create a duplicate context file merely because a skill template names it.
Use existing domain names consistently:

- `DictationSession`: the push-to-talk lifecycle and its snapshotted config.
- `AppState`: composition and app-level policy, not the pipeline owner.
- `ModelAvailability`: the single readiness answer.
- `TextInserting`: insertion into another application; reported delivery
  certainty must be distinguished from posting a paste event.
- `DictationPresenting` / `PanelState`: the non-activating dictation indicator.
- `DailyStats`: local aggregate counts/timings, never captured transcript text.

If a proposal contradicts a recorded decision, name the conflict and the new
evidence that would justify reopening it. Do not repeat rejected experiments
without reading their provenance and limits. Work states and acceptance
criteria belong in [ROADMAP.md](../ROADMAP.md), not a competing backlog here.
