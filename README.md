# Linux Process and Resource Leak Analyzer

A read-only Bash toolkit for identifying CPU spikes, memory growth, zombie processes, excessive thread counts, open-file pressure, and system resource exhaustion.

## Checks performed

- Load average, uptime, CPU, memory, swap, and pressure-stall information
- Top processes by CPU, resident memory, thread count, elapsed time, and open files
- Zombie and uninterruptible-sleep processes
- Per-process file descriptor counts
- System-wide file handle and process limits
- Two process snapshots to highlight RSS growth
- OOM-killer, hung-task, and resource-exhaustion events
- Text, CSV, and JSON reports

## Usage

```bash
chmod +x src/process_resource_analyzer.sh
sudo ./src/process_resource_analyzer.sh
```

```bash
sudo ./src/process_resource_analyzer.sh --sample-seconds 10 --top 25 --output /tmp/process-analysis
```

## Safety

The script does not kill, renice, pause, trace, restart, or modify processes and services.

## Requirements

- Bash 4+
- Standard Linux `/proc` filesystem
- Optional `lsof`, `pidstat`, and `systemd` tools for richer evidence

## Author

Dewald Pretorius — L2 IT Support Engineer
