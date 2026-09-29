# Repository / Versioning Policy

## Source of truth
`git@github.com:papataku/honda_ehev_analyzer.git` is the canonical source.
Do not treat a generated ZIP or a local extracted directory as the master once a change has been committed.

## Branch policy
- `main`: latest reviewed, test-passing baseline suitable for the next planned vehicle test.
- Use a feature/issue branch for larger or risky work when practical.
- Do not rewrite `main` history for normal development.

## Versioning
Use semantic-style project versions currently in the `0.x.y` series.
For a release baseline, keep these aligned:
- `pyproject.toml` project version,
- `src/honda_analyzer/__init__.py` `__version__`,
- `src/honda_analyzer/build_info.py`,
- `CHANGELOG.md`,
- release/review notes,
- `docs/DEVELOPMENT_STATE.md`.

`BUILD_ID`/`SOURCE_HASH` exist so distributed source can still be identified when `.git` metadata is absent. A normal Git checkout should additionally record the Git commit in captured session metadata when available.

## Verification before updating main
Run at minimum:
```bash
python -m pytest -q
python -m compileall -q src
```
When a real vehicle issue motivated the change, add a regression using real-format anonymized/minimal evidence or a deterministic equivalent and document what was observed.

## Evidence classification
- KNOWN/VERIFIED: standard definition or independently validated vehicle signal.
- CANDIDATE: evidence supports a hypothesis but semantics are not yet established.
- UNKNOWN/TODO-VEHICLE-TEST: do not name as a confirmed Honda signal.

Do not silently promote candidates.

## Data policy
Do not commit by default:
- session ZIPs,
- SQLite session databases,
- raw BLE captures,
- trip/location-bearing Debug Bundles,
- user-specific application logs.

Use tests/synthetic fixtures or minimal anonymized excerpts instead.

## Release artifacts
Release ZIPs may be generated for convenience, but code changes should land in Git first. The ZIP should be reproducible from the committed tree and its version/build metadata should identify the source baseline.
