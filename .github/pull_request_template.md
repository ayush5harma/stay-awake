## Summary

Describe the user-visible change and any effect on `pmset`, `caffeinate`, idle locking, authorization, installation, or uninstall.

## Checks

- [ ] `bash -n build.sh install.sh`
- [ ] `shellcheck -S warning build.sh install.sh`
- [ ] Scratch build completed, when Swift sources or build scripts changed
- [ ] Documentation matches the current behaviour
