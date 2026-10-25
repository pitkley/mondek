# Investigating missing measurements

Open an unavailable, overdue or pending result and choose **Investigate measurement**. This keeps the selected result, owning runner and original inventory filters together. The page updates as new evidence arrives; **Back to result** returns to the same result and its filtered inventory.

## Follow the evidence

The finding at the top identifies the next useful inspection, not a proven root cause. A runner can lose controller access while continuing to execute checks. Recent contact can coexist with a broken datasource or old source data.

| Finding | Next inspection |
| --- | --- |
| Collection unavailable | Read the latest execution diagnostic and collection details. Check the named datasource's configuration, network access and permissions from the runner's environment. |
| Runner contact overdue | Inspect the runner process and its outbound controller connection. Its last reported queue counts may already be old. |
| Waiting for configuration | Compare desired, prepared and active versions; inspect preparation errors and the installed consumer. |
| Measurement overdue | Compare original source, evaluation and controller receipt times. Check cached source data, scheduling and buffered reports. |
| Waiting for measurement | Inspect the first due execution in this session/configuration. A heartbeat alone cannot establish coverage. |
| No runner assigned | Attach the intended runner and review its declarations and placement in Coverage. |
| Result retired | Review source removal/replacement and history. No further measurement is expected; retirement is not recovery. |

Latest execution details are distinct from retained confirmed health. An unavailable execution can follow a Critical measurement; both pieces of evidence remain useful, but the earlier Critical verdict does not become a new measurement. The investigation page shows the most recently received execution, including after reconnect, without changing its original timestamps.

## Runner signals have limits

Configuration versions belong to this scheduled check. Running, due-waiting, buffered and dropped report counts cover the whole runner. They cannot identify which specific check is blocked. Status is the runner's last report and may predate its latest controller contact; the controller cannot advance those counts while disconnected. A brief upload queue can be normal. Dropped reports are cumulative for the journal, and the last recorded diagnostic may survive recovery.

Use **Full status for this runner** for additional spool/scheduling details. For a datasource problem, inspect the datasource from the runner's network, using its execution context and mounts. A successful connection from a laptop or controller does not prove that the runner has access. Keep credential values, environment files, authenticated URLs and upstream response bodies out of shared diagnostics.

## Notifications and coding agents

Notification delivery does not determine whether checks execute. Acknowledgement and maintenance hold notifications while collection continues. Follow the related incident's timeline to inspect holds, attempts and delivery errors. Prolonged unavailable or overdue measurements now open a separate [monitoring-loss incident](MONITORING-LOSS.md), grouped by runner; they never manufacture a target-health failure. Monitoring loss and measured-health incidents have independent acknowledgements and histories.

The **Investigate a measurement problem** agent prompt includes bounded identity and status context only. It excludes parameters, result text and raw diagnostics; review it before manually copying it to an agent. The prompt asks for a read-only investigation, with narrowly relevant redacted evidence when necessary.

## Local verification

```sh
devenv shell -- python3 tests/browser/run.py --suite diagnostics
```

This runs the installed demo runner against a real local datasource, forces an execution timeout, restores collection, partitions controller transport and verifies buffered evidence after reconnect. All services are isolated and removed afterward. Screenshots, accessibility results and test reports remain under `.local/browser/`.
