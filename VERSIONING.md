# Versioning (Kalcor / SA-MP system)

The base version lives in the `VERSION` file. CI derives the build version:

- **Letter releases** — `0.1a`, `0.1b`, ... `0.1z`, then `0.2a`. A new letter
  means new features. Bump by editing `VERSION`.
- **R revisions** — every further commit while `VERSION` is unchanged rebuilds
  the same version as a revision: `0.1a R2`, `0.1a R3`, ... (fixes/patches,
  same feature set — like SA-MP's `0.3z R2`).
- **RC pre-releases** — set `VERSION` to e.g. `0.1b RC` and every commit
  builds `0.1b RC1`, `0.1b RC2`, ... published as GitHub pre-releases.
  When stable, set `VERSION` to `0.1b` — the next build is the final.

Ordering: `0.1a RC1 < 0.1a RC2 < 0.1a < 0.1a R2 < 0.1a R3 < 0.1b`.

Git tags replace the space with a dash: `v0.1a-R2`.
