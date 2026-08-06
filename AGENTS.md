# Project agent instructions

## Immutable files

- Do not modify `INSTRUCTIONS.md`. Preserve its exact contents and hash across every revision.

## CI monitoring

- Push every `main` update to both `origin` (GitHub) and `fork` (SourceHut). Pushing only to `origin` does not trigger the SourceHut build.
- Limit each wait for a queued CI run to 30 seconds unless the run starts or otherwise makes progress.
- When GitHub has no available runner, record the run ID, status, and URL, then continue independent work instead of polling indefinitely.
- Recheck pending runs after other work completes.
