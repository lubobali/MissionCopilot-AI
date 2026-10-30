# Device baseline (spike prerequisite)

- Device: iPhone 13 Pro Max (A15, 6 GB RAM), iOS 27.2, Debug build, free provisioning.
- **Free memory for the app at launch: 2.98 GB** (`os_proc_available_memory`, Lab screen, Oct 30 2026).
- Budget for the on-device model (1.2B, 4-bit): weights about 0.7 GB plus cache and runtime, target
  under 1.5 GB, hard limit 2 GB (spike #12 GO criterion). The increased-memory-limit entitlement is
  likely unavailable on a free team, so we stay inside the default budget.
- Model files arrive in the app's Documents inbox (Finder file sharing or `xcrun devicectl device copy to`)
  and are moved into Application Support/models by the Lab's import button.
