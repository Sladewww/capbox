# Strict package locks

Requires host Python **3.10+**.

`image lock save` creates a JSON schema-1 lock with distro, architecture and the complete installed package/version set. It refuses an empty inventory, failed package query or incomplete dpkg package state.

```sh
capbox image lock save
capbox image lock show
capbox image lock verify
capbox image lock restore /path/to/package.lock
capbox recipe apply --locked /path/to/package.lock capbox.recipe
```

`verify` compares the complete current set: missing packages, extra packages and version mismatches are errors. `restore` installs exact `name=version` arguments through `capbox pkg`, then verifies the result. The normal network exception for package installation and the Alpine script compatibility filter remain in effect.

Locked recipe application checks that the lock satisfies every requested recipe package (including explicit versions) before committing configuration. An unavailable version, wrong distro/architecture, malformed lock or version mismatch fails. No unpinned fallback occurs. Existing newer packages may prevent a package manager from downgrading automatically; failure is explicit. Package-manager changes are not transactionally rolled back: back up important guest state before restoration.

Locks record package versions; they do not archive repository contents or pin host kernels. For durable reconstruction, retain trusted repository snapshots or CapBox rootfs exports as well. A successful lock restoration verifies package identity/version, not arbitrary application file contents.

The pre-0.3.6 `package.lock` text file was an inventory, with no strict replay contract. It is rejected by `verify`/`restore`; regenerate it with `image lock save` on the environment you want to record. The file is data and is never sourced.
