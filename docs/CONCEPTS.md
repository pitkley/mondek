# How Mondek fits together

Mondek runs monitoring checks written in Python and shows what they measured. Your code defines what exists, how to collect it and what the results mean. You can use ordinary functions, libraries and your own abstractions, with optional standard check packs for common observations. The web UI lets operators inspect evidence and change the settings your code deliberately exposes.

## Server, runners and your monitoring project

The **Mondek server** is the central application: the web UI, result and incident history, delegated configuration, and notification delivery. It stores and evaluates reports; it never imports or executes your Python monitoring code. Implementation and protocol documentation also call this component the **controller**. Paths such as controller/ and settings such as MONDEK_CONTROLLER_URL retain that technical name.

A **runner** is a long-running process near the things it can observe. It loads your installed monitoring project, executes its checks on their schedules and sends the original measurements to the server. During a transport outage it continues collecting and buffers a bounded amount of evidence. Each runner needs its own persistent state directory; that state identifies the installation and retains buffered reports across restart.

Your **monitoring project** is a separate Python package containing checks, datasource access and monitoring policy. SDK and CLI references call this a **consumer package**. The **SDK** is the mondek_runner Python package used to declare and run that code. The SDK is part of Mondek's source; an experimental source installation uses a locally built wheel rather than a published registry package.

A **Mondek installation** includes a server and the runners attached to it. “Site” is not a separate object you must configure. A monitored environment such as Production describes the subjects being monitored, not a separate server installation or necessarily the place a runner executes.

## A concrete example

Suppose you want to monitor a queue's backlog. Your Python function reads a file or queries an API, compares the depth with thresholds and returns a result. You install that project on a runner with access to the queue. The server receives the result, displays its health and original measurement time, and records any resulting incident or notification.

| Term | Queue example |
| --- | --- |
| Source | The monitoring project's stable identity |
| Check | The scheduled Python function and its configuration |
| Result | The independently tracked backlog measurement, such as 12 pending items |
| Target | The queue that measurement describes |
| Monitored environment | Production, even if the runner queries its API from elsewhere |
| Runner | The process with access to the queue's data |

One scheduled check can return several declared results, each with independent health and history. Two runners can observe the same target while retaining their own evidence. Keep stable IDs when the subject and meaning remain the same; display labels can change independently.

## Code and UI responsibilities

Code owns check membership, collection behavior, schedules, target identities, datasource access and credentials. A `Parameter` declaration can delegate a threshold or other operational setting to the UI, with explicit defaults and validation. Saving a value is followed by runner preparation, activation and measurement; the new value is not proved active just because it was saved.

Measured health and evidence availability are separate. A recent runner connection does not prove that a check collected successfully, and an old healthy measurement does not become fresh when transport recovers. See [operations](OPERATIONS.md) for the detailed behavior.

Continue with [your first installation and monitoring project](GETTING-STARTED.md), or the [Python SDK guide](SDK.md) if you are ready to write checks.
