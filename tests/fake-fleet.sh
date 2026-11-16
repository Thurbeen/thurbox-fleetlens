#!/bin/sh
# A stand-in for fleet in the unit tests: prints FAKE_JSON, exits FAKE_EXIT.
printf '%s\n' "$FAKE_JSON"
exit "${FAKE_EXIT:-0}"
