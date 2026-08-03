# Contributing

Thanks for your interest in Claude Orchestrator. This is a small, opinionated
personal tool — contributions are welcome, but please keep the two points below
in mind before opening a pull request.

## How to contribute

1. Open an issue first for anything non-trivial, so we can agree on the approach
   before you spend time on it.
2. Fork, branch, and keep changes focused — one concern per PR.
3. Match the surrounding style. Swift for the apps (`app-native/`,
   `launcher-native/`), bash/Python for `bin/`.
4. Build locally before submitting:
   - `cd app-native && swift build`
   - `cd launcher-native && swift build`
5. The repo uses `pre-commit` (secret scanning + hygiene). Install it with
   `pre-commit install` and make sure `pre-commit run --all-files` passes.

## Developer Certificate of Origin (DCO)

Every commit must be signed off, certifying you have the right to submit it under
the terms below. Sign off by adding a `Signed-off-by` line with `git commit -s`
(or `-s` on `git commit --amend`), which appends:

```
Signed-off-by: Your Name <your.email@example.com>
```

Use your real name and an email you can be reached at. By signing off, you certify
the following (this is the standard Developer Certificate of Origin, version 1.1):

```
Developer Certificate of Origin
Version 1.1

Copyright (C) 2004, 2006 The Linux Foundation and its contributors.
1 Letterman Drive
Suite D4700
San Francisco, CA, 94129

Everyone is permitted to copy and distribute verbatim copies of this
license document, but changing it is not allowed.


Developer's Certificate of Origin 1.1

By making a contribution to this project, I certify that:

(a) The contribution was created in whole or in part by me and I
    have the right to submit it under the open source license
    indicated in the file; or

(b) The contribution is based upon previous work that, to the best
    of my knowledge, is covered under an appropriate open source
    license and I have the right under that license to submit that
    work with modifications, whether created in whole or in part
    by me, under the same open source license (unless I am
    permitted to submit under a different license), as indicated
    in the file; or

(c) The contribution was provided directly to me by some other
    person who certified (a), (b) or (c) and I have not modified
    it.

(d) I understand and agree that this project and the contribution
    are public and that a record of the contribution (including all
    personal information I submit with it, including my sign-off) is
    maintained indefinitely and may be redistributed consistent with
    this project or the open source license(s) involved.
```

## Licensing of contributions

This project is distributed under the
[PolyForm Noncommercial License 1.0.0](LICENSE), and the copyright holder also
offers it commercially under separate terms.

By contributing, in addition to the DCO above, you agree that:

1. Your contribution is provided under the same PolyForm Noncommercial License
   1.0.0 as the rest of the project; and
2. You grant the project's copyright holder (Peter Strimbu) a perpetual,
   worldwide, non-exclusive, royalty-free, irrevocable license — with the right
   to sublicense — to use, reproduce, modify, and distribute your contribution,
   and to **relicense it under any terms, including commercial or proprietary
   licenses**.

You retain copyright in your contribution. This grant simply ensures the project
can continue to be offered both noncommercially and commercially without needing
to track down every contributor for permission. If you can't agree to this,
please don't submit a contribution.

If you're contributing on behalf of your employer, make sure you have the right
to do so under the terms above.
