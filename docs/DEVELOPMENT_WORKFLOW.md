# Development and Release Workflow

## Branch / repository policy
- Canonical remote: `git@github.com:papataku/honda_ehev_analyzer.git`
- `main` is the integrated baseline unless a task explicitly calls for a feature branch.
- Keep a clean, reproducible commit history. Use focused commit messages explaining the observed problem and the behavior change.

## Versioning
Use semantic-style project versions already established by the project (`0.x.y`).

For every release-level change:
1. update `pyproject.toml`,
2. update `src/honda_analyzer/__init__.py`,
3. add/update `CHANGELOG.md`,
4. add release notes under `docs/` when behavior is substantial,
5. ensure Debug Bundles record version + build/source identity,
6. tag stable release commits as `vX.Y.Z` when practical.

## Definition of done
Before calling a build ready:
- full `pytest -q` passes,
- `python -m compileall -q src` passes,
- new real-vehicle defect has a regression test,
- safety and UI behavior are reviewed,
- docs/context are updated if assumptions or evidence changed,
- generated caches are excluded from release artifacts.

## Real-vehicle evidence workflow
1. Reproduce the issue or collect a session/debug bundle.
2. Preserve raw evidence before interpretation.
3. Add a regression fixture/test based on the observed format without checking private raw trip data into the public repo.
4. Fix parser/protocol/analysis/UI behavior.
5. Re-run older regressions so a new vehicle case does not break replay or synthetic cases.
6. Document what is confirmed vs still candidate/unknown.

## Safety review checklist for diagnostic changes
- Does this change send anything other than read-only requests?
- Can it run while vehicle speed is non-zero?
- What happens if speed becomes unknown?
- Can an ELM timeout or malformed response cause command overlap?
- Can a long response be mistaken for an unsupported DID?
- Is the response preserved even when analysis fails?

If any answer is unsafe or ambiguous, do not enable the feature for real vehicle use.

## UI review checklist
Review as multiple user backgrounds:
- PC beginner,
- vehicle/CAN beginner,
- software engineer new to automotive,
- automotive engineer new to the app,
- data analyst.

For each button/page verify:
- what it does is stated,
- prerequisites are visible,
- disabled-state reason is visible,
- failure produces a useful message rather than no-op,
- terminology is explained,
- small Mac displays can reach all controls via resize/scroll.

## Repository hygiene
Do not commit:
- `.venv/`, caches, local DBs,
- raw user drive/session ZIPs,
- private device identifiers unless intentionally anonymized,
- generated debug bundles.

Do commit:
- source,
- tests,
- synthetic or sanitized fixtures,
- docs,
- release notes,
- deterministic definitions/configuration needed to reproduce analysis.
