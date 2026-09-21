# Capacity and diagnostic log regression checks

Run with Xcode 26 or newer (Swift 6.2), matching the application's compiler:

```sh
DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer bash Tests/run-regression-tests.sh
```

These checks compile the production plist parser with the app's default actor isolation and optimization enabled. They cover duplicate UUIDs, ambiguous targets, device identity changes, malformed responses, and capacity bounds. The tests use synthetic plists and do not query or modify disks.

The log checks compile the production logger and verify raw response persistence, retention of ten queries, and rotation of one 8 MB workflow history. They use a temporary Foundation home directory and refuse to run if that override is not honored, leaving the user's real logs untouched.
