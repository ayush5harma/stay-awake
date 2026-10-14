# Contributing

Thanks for improving Stay Awake. Please keep changes small, explain changes to power-management behaviour clearly, and avoid committing generated app bundles or local logs.

## Development

Build into a scratch directory so development never alters an installed copy:

```sh
scratch=$(mktemp -d)
APP_DIR="$scratch" bash build.sh --force
```

Run the applicable checks before opening a pull request:

```sh
for script in build.sh install.sh; do bash -n "$script"; done
shellcheck -S warning build.sh install.sh
```

The app has no package manager or test framework. A successful scratch build is the compile check. Do not run `install.sh` as part of routine development: it registers a LaunchAgent, and turning the app on changes a system-wide `pmset` setting.

## Contributions that affect power or authorization

Describe the before-and-after behaviour for `pmset`, `caffeinate`, idle locking, launch-at-login, and uninstall as applicable. Never widen the sudoers example without explaining why the existing two-command allowance is insufficient.

## Security issues

Please do not file public issues for a suspected privilege escalation, authorization bypass, or secret exposure. Use [private security-advisory reporting](https://github.com/ayush5harma/stay-awake/security/advisories/new).

## Licence

By contributing, you agree that your contribution is available under the repository's MIT licence.
