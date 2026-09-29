# Canonical source bootstrap (v0.3.4)

This is a one-time recovery step for the initial GitHub import.

## Why this exists

The project was originally developed and tested as a release ZIP before
`git@github.com:papataku/honda_ehev_analyzer.git` was designated as the
canonical repository. Documentation and part of the source are already in
GitHub, but the full tested v0.3.4 tree must be materialized once from the
verified release ZIP.

The verified ZIP is:

`honda_ehev_can_uds_analyzer_0.3.4_long_did_recovery.zip`

Expected SHA-256:

`bae24021b3ca8b1587817821f2db7799ccac3f9dc707aecad962382a30c20d3d`

## One-time Mac procedure

Clone the canonical repository and run the committed helper with the verified
ZIP path:

```bash
git clone git@github.com:papataku/honda_ehev_analyzer.git
cd honda_ehev_analyzer
bash tools/bootstrap_v034_from_zip.sh \
  ~/Downloads/honda_ehev_can_uds_analyzer_0.3.4_long_did_recovery.zip \
  --push
```

The helper refuses a ZIP whose SHA-256 differs from the known tested release.

It then:

1. extracts the release;
2. verifies version 0.3.4 and key source/test files;
3. copies the complete `src/`, `tests/`, `docs/` and `signals/` tree;
4. preserves repository-only context documents such as `AGENTS.md`,
   `docs/PROJECT_CONTEXT.md`, `docs/DEVELOPMENT_STATE.md` and
   `docs/REPOSITORY_POLICY.md`;
5. removes temporary bootstrap/import artifacts;
6. creates a Python 3.12 environment;
7. installs `.[dev]`;
8. runs the complete pytest suite and compileall;
9. commits only if verification succeeds;
10. pushes the resulting canonical tree to `main` when `--push` is supplied.

## After bootstrap

The GitHub repository becomes the source of truth. Future changes should be
made from Git, tested, versioned, documented in CHANGELOG/current-state notes,
then optionally packaged into release ZIPs.

Do not use an old extracted ZIP as the development master after the bootstrap.
