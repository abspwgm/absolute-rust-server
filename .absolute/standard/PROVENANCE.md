# Vendored standard

This directory is a copy of the machine-readable half of the Absolute
engineering standard, standard version **1.0.0**, matching the
`standard_version` declared in `../policy.yml`.

The four files below were copied verbatim from the copy already vendored in
`abspwgm/absolute-palworld-server` at `.absolute/standard/`, which was itself
taken from the standard at commit
`fb8ff70ecd01e6e6f23291d442d69f310ded08f6`. They are byte-identical to the
copies carried by `absolute-palworld-server` and `absolute-server-template`,
so all three repositories are checked by the same code against the same
baseline. Nothing here was edited for this repository.

It is vendored because the standard now lives in a private repository, and a
public repository cannot call a reusable workflow from a private one. Only what
`check.py` actually reads is here — the prose (`STANDARD.md`, `BASELINE.md`)
is not.

| Path | What it is |
|---|---|
| `VERSION` | The standard version `check.py` compares against `../policy.yml` (7.3) |
| `conformance/check.py` | The conformance check |
| `security/baseline.policy.yml` | The seven-layer security floor (clause 6) |
| `security/base-images.yml` | The approved base image library |

## The one difference from the original

The secret-scanner escape hatch is spelled `absolute-conformance:allow-secret`
here, not the name the standard uses. The old spelling contained the private
repository's name, which is the thing this copy exists to avoid publishing. No
file in this repository uses the marker.

## Keeping it current

`check.py` compares `VERSION` against `../policy.yml` exactly, so these move
together or the check fails. Refreshing to a newer standard means copying these
four files again from that version and bumping `standard_version` in the same
pull request.
