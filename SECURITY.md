# Security Policy

## Supported versions

Only the latest release of Tuno receives security fixes. Tuno updates itself, and the latest version is always available at [gettuno.info](https://gettuno.info) and on the [releases page](https://github.com/CanerKarakus/Tuno/releases).

## Reporting a vulnerability

Please don't open a public issue for security problems. Email **tuno@geidostudio.com** with:

- a description of the problem and its impact,
- steps to reproduce it,
- your Tuno and macOS versions.

You'll get a reply within a few days. Once the issue is confirmed, a fix is released as soon as possible and you'll be credited in the release notes if you'd like.

## Verifying a download

Official builds are signed with Developer ID **72XQ32HJ4C** and notarized by Apple. To check a copy:

```sh
codesign -dv --verbose=2 /Applications/Tuno.app   # TeamIdentifier=72XQ32HJ4C
spctl -a -vv /Applications/Tuno.app               # source=Notarized Developer ID
```

Each release on GitHub lists the SHA-256 checksum of its disk image.
