# Transfer Reliability Checklist

## Keep Transfers Running With Screen Off

- [x] Run transfers from a foreground data-sync service.
- [x] Hold a partial CPU wake lock during active sessions.
- [x] Hold a high-performance Wi-Fi lock during active sessions.
- [x] Hold a multicast lock so local discovery remains stable.
- [x] Prompt the user to allow MiDoid through Android battery optimization.
- [x] Add a persistent settings row that shows battery-optimization status.
- [x] Add vendor-specific guidance for aggressive OEM battery managers.

## Throughput

- [x] Increase Android response stream buffer (raised to 256 KB).
- [x] Avoid opening Finder after every file in a multi-file transfer.
- [x] Add a transfer diagnostics panel with Wi-Fi band, link speed, and rolling throughput.
- [x] Parallelize folder transfers with a small concurrency limit (3 concurrent).
- [ ] Parallelize individual file downloads across the transfer queue (not just within a single folder job).
- [ ] Consider a direct TCP large-file path for videos instead of WebDAV (deferred — WebDAV + Range + 256 KB buffer covers typical use; revisit if >500 MB video benchmarks show a bottleneck).

## Resume And Recovery

- [x] Support resumable downloads with HTTP Range and partial local files (.midoid-part survives crashes).
- [x] Add temp-file writes on Mac, then atomic rename after completion.
- [x] Add clearer retry messaging for sleeping phone, Wi-Fi change, and storage errors.
- [x] Keep failed transfer metadata long enough to retry after reconnect.

## UX

- [x] Show speed and ETA.
- [x] Smooth transfer speed over a rolling window.
- [x] Show Android in-app transfer progress.
- [x] Sort received Mac files by type into Photos, Videos, Documents, Audio, Archives, and Other.
- [x] Add a destination-folder setting for received files.
- [x] Add a post-transfer summary grouped by file type.
