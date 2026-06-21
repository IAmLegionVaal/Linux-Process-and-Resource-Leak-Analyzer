# Linux Process and Resource Leak Analyzer

A Linux support toolkit for diagnosing CPU, memory, thread, file-descriptor and resource-pressure problems and applying selected guarded repairs.

## Diagnostic script

```bash
chmod +x src/process_resource_analyzer.sh
sudo ./src/process_resource_analyzer.sh
```

The diagnostic script reports load, memory, swap, pressure stalls, top processes, zombies, blocked tasks, file descriptors, growth between samples and recent OOM or hung-task events.

## Repair script

Preview a service restart:

```bash
chmod +x src/process_resource_repair.sh
sudo ./src/process_resource_repair.sh \
  --restart-service example.service \
  --dry-run
```

Restart or clear failure state for one service:

```bash
sudo ./src/process_resource_repair.sh --restart-service example.service
sudo ./src/process_resource_repair.sh --reset-failed example.service
```

Terminate one selected non-system user process:

```bash
sudo ./src/process_resource_repair.sh --terminate-pid 1234
```

Use `--force` only when the selected process ignores the normal termination request.

Change the priority of one selected non-system user process:

```bash
sudo ./src/process_resource_repair.sh --renice 1234 10
```

## What the repair does

- Restarts or clears failure state for one selected systemd service.
- Sends a normal termination request to one selected non-system user process.
- Can send a forceful termination request only after the normal request fails and confirmation is given.
- Can change the nice value of one selected non-system user process.
- Refuses low system PIDs and directs system-owned process repair through systemd.
- Captures resource and process state before and after repair.
- Supports dry-run, confirmation prompts, logs and clear exit codes.

## Safety and limitations

Stopping a process can lose unsaved work. Process termination and priority changes are restricted to non-system user processes. Kernel, hardware, memory and storage faults require separate investigation.

## Author

Dewald Pretorius — L2 IT Support Engineer
