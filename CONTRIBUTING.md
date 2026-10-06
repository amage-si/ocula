# Contributing to Ocula

Use Bend 2.0.35 for the current baseline. Read `bend guide` before editing Bend
and keep project text in English. Library implementation belongs in Bend; the
official runtime and operating system remain external dependencies.

## Validation

From the repository root:

```sh
export BEND_NO_TELEMETRY=1
mkdir -p build
bend tests.bend -o build/tests
./build/tests --threads 2 --gpu off
bend examples/decode.bend -o build/decode
python3 tools/oracle.py --verify build/decode --output build/oracle
```

`--output` must name a new directory. Add `--real` to also compare the four
PNGs from `/usr/share/pixmaps` with ImageMagick when they and `magick` are
available.

When you add or change a fixture, edit `tools/oracle.py`, regenerate with
`python3 tools/oracle.py --prepare-only`, and commit the fixtures together with
the regenerated `fixtures/cases.bend`, `fixtures/reads.bend`, and
`fixtures/manifest.json`. Keep every existing case.

Build one target at a time. The native Bend runtime reserves substantial virtual
address space; a virtual-memory limit is not a resident-memory limit. Preserve
crash evidence and investigate before repeating a failed compiler invocation.

## Changes

Keep the API small and ownership explicit. Add a focused regression check when
behavior changes: a valid fixture for each newly accepted feature and an invalid
one for its edge, update affected contracts, and report what was actually
validated.

Use English commit messages that explain the result. Do not commit `build/`,
generated C, decoder outputs, logs, crash dumps, credentials, or
machine-specific paths. Do not publish BendHub packages or create releases as a
side effect of validation.
