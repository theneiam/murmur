# Security policy

Murmur runs entirely on your Mac and holds Accessibility and Microphone
permissions, so security reports are taken seriously.

## Supported versions

Only the latest release on the [releases page](https://github.com/theneiam/murmur/releases)
receives fixes.

## Reporting a vulnerability

Please **do not open a public issue** for security problems. Use GitHub's
private vulnerability reporting: *Security → Report a vulnerability* on the
repository. You will get an acknowledgement within a few days and a fix or a
mitigation plan as soon as one exists. Credit is given in the release notes
unless you prefer otherwise.

Things that count: anything that would let dictated audio or text leave the
machine, be written to disk unexpectedly, or be inserted somewhere the user did
not intend; anything that abuses the event tap or the Accessibility grant; and
supply-chain concerns in the build or release pipeline.
