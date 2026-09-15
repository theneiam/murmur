# Issue tracker

The configured remote is `git@github.com:theneiam/murmur.git`. Public issues
and PRDs belong to **theneiam/murmur on GitHub**, accessed through `gh` or the
GitHub connector when available. Read existing issues before creating a new
one; keep each issue's problem, acceptance criteria and verification evidence
together.

The approved project review is tracked **locally** in
[ROADMAP.md](../ROADMAP.md). `MUR-001` and similar entries are local IDs, not
GitHub issue numbers. Update those entries for this work. A request to use an
engineering skill does not by itself authorize posting issues/comments or
creating labels; follow the explicit task scope and AGENTS.md working
agreements. No GitHub issue, label or external message was created by setup.

When an explicitly authorized task says “publish to the issue tracker,” use
GitHub, specify `--repo theneiam/murmur`, and link the resulting issue back to
the local roadmap if relevant. For multiline issue/comment text, use a
structured tool argument or an exact temporary file with `--body-file`.
When asked to fetch `MUR-…`, read the local roadmap; for `#123` or a GitHub URL,
read that GitHub issue and its comments. Do not invent issue numbers.
