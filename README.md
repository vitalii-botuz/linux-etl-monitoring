# Linux ETL Pipeline Monitoring

A Linux-based portfolio project demonstrating a scheduled Python ETL worker, UTC logging, systemd services and timers, automated health checks, log rotation, and Telegram alerting.

The ETL workload is simulated. The project focuses on Linux administration, service scheduling, monitoring, failure detection, and troubleshooting rather than processing data from a real database.

## Architecture

- `etl_worker.py` — simulated ETL worker with normal, failure, and empty-data execution modes.
- `healthcheck.sh` — checks application logs, filesystem usage, and systemd execution history over the last 24 hours.
- `systemd/etl-pipeline.service` — runs the ETL worker as the dedicated unprivileged `etl` user.
- `systemd/etl-pipeline.timer` — schedules the ETL worker daily at 02:00 UTC.
- `systemd/etl-healthcheck.service` — runs health checks with root privileges.
- `systemd/etl-healthcheck.timer` — schedules health checks daily at 03:00 UTC.
- `logrotate/etl-pipeline` — rotates application logs daily and retains 14 rotations.
- `telegram.env.example` — example configuration for Telegram notifications.

### Monitoring workflow

1. The ETL worker runs on schedule and writes logs to `/var/log/etl/pipeline.log`.
2. The healthcheck examines log signals from the previous 24 hours.
3. It checks filesystem usage and systemd execution history.
4. If an issue is detected, it sends a Telegram notification.
5. Application logs and journald provide diagnostic information for troubleshooting.

## Requirements

- Ubuntu/Debian Linux
- Python 3
- systemd
- logrotate
- Telegram bot (optional, for notifications)

The Python worker uses only the standard library.

## Installation

### 1. Create the service user and directories

Run commands with administrator privileges:

```bash
sudo useradd --system --user-group \
  --home-dir /opt/etl-pipeline \
  --shell /usr/sbin/nologin etl

sudo mkdir -p /opt/etl-pipeline /var/log/etl /etc/etl

sudo chown root:etl /opt/etl-pipeline
sudo chmod 0750 /opt/etl-pipeline

sudo chown etl:etl /var/log/etl
sudo chmod 0750 /var/log/etl
```

### 2. Copy project files

Copy the application files and configuration directories into `/opt/etl-pipeline`.

For example, from the project root:

```bash
sudo cp etl_worker.py healthcheck.sh telegram.env.example /opt/etl-pipeline/
sudo cp -r systemd logrotate /opt/etl-pipeline/

sudo chown -R root:etl /opt/etl-pipeline
sudo chmod 0640 /opt/etl-pipeline/etl_worker.py
sudo chmod 0750 /opt/etl-pipeline/healthcheck.sh
```

### 3. Create the Python virtual environment

```bash
sudo python3 -m venv /opt/etl-pipeline/venv
sudo chown -R root:etl /opt/etl-pipeline/venv
```

The ETL worker runs using the virtual environment's Python interpreter.

### 4. Configure Telegram notifications

Create a Telegram bot using BotFather, send it a message, and obtain the chat ID.

```bash
sudo cp /opt/etl-pipeline/telegram.env.example /etc/etl/telegram.env
sudo nano /etc/etl/telegram.env

sudo chown root:root /etc/etl/telegram.env
sudo chmod 0600 /etc/etl/telegram.env
```

Add the bot token and chat ID to the configuration file.

Never commit the real bot token or `/etc/etl/telegram.env` to Git. The configuration file must remain readable only by root.

### 5. Install systemd units and logrotate configuration

```bash
sudo cp /opt/etl-pipeline/systemd/*.service /etc/systemd/system/
sudo cp /opt/etl-pipeline/systemd/*.timer /etc/systemd/system/

sudo cp /opt/etl-pipeline/logrotate/etl-pipeline /etc/logrotate.d/etl-pipeline

sudo systemctl daemon-reload
```

Validate the systemd configuration:

```bash
sudo systemd-analyze verify \
  /etc/systemd/system/etl-pipeline.service \
  /etc/systemd/system/etl-healthcheck.service \
  /etc/systemd/system/etl-pipeline.timer \
  /etc/systemd/system/etl-healthcheck.timer
```

Enable and start both timers:

```bash
sudo systemctl enable --now etl-pipeline.timer etl-healthcheck.timer
```

Check their status and schedule:

```bash
systemctl list-timers --all
systemctl status etl-pipeline.timer etl-healthcheck.timer --no-pager
```

### Schedule

| Component | Schedule |
|---|---|
| ETL worker | Daily at 02:00 UTC |
| Healthcheck | Daily at 03:00 UTC |

The healthcheck is scheduled one hour after the ETL worker.

## Manual testing

Run the worker in its three supported modes:

```bash
sudo -u etl /opt/etl-pipeline/venv/bin/python /opt/etl-pipeline/etl_worker.py

sudo -u etl /opt/etl-pipeline/venv/bin/python /opt/etl-pipeline/etl_worker.py --fail

sudo -u etl /opt/etl-pipeline/venv/bin/python /opt/etl-pipeline/etl_worker.py --empty
```

Expected behavior:

| Mode | Expected result |
|---|---|
| Normal | Loads simulated rows and exits with code 0 |
| `--fail` | Simulates a connection error and exits with code 1 |
| `--empty` | Loads 0 rows but exits with code 0 |

The `--empty` mode demonstrates a business/data-quality failure that cannot be detected by checking the process exit code alone.

Run the healthcheck manually:

```bash
sudo /opt/etl-pipeline/healthcheck.sh
```

The healthcheck may send a Telegram alert if it detects a failure signal in the previous 24 hours or filesystem usage above the configured threshold.

## Linux diagnostics

### systemd status and logs

```bash
systemctl status etl-pipeline.service --no-pager
systemctl status etl-healthcheck.service --no-pager

journalctl -u etl-pipeline.service --since "24 hours ago" --utc
journalctl -u etl-healthcheck.service -n 50 --no-pager
```

### Application logs

```bash
grep -nE 'ERROR|Traceback|0 rows loaded' /var/log/etl/pipeline.log

grep -n -B 5 -A 15 'ERROR' /var/log/etl/pipeline.log
```

### Disk usage

```bash
df -h /var/log/etl
du -sh /var/log/etl
sudo du -ah /var/log | sort -h | tail -n 20
```

### Timers and log rotation

```bash
systemctl list-timers --all

sudo logrotate -d /etc/logrotate.d/etl-pipeline
```

## Example Telegram alert

```text
ETL PIPELINE ALERT

Time (UTC): 2026-11-13T03:00:02Z

Detected issues:
LOG: critical signal found in the last 24 hours

Likely root cause:
Likely ETL runtime failure: database connection error/exception.

Last log lines:
2026-11-13T02:00:00Z | INFO | etl | ETL pipeline started
2026-11-13T02:00:01Z | ERROR | etl | source database connection failed
Traceback (most recent call last):
...
```

## Root-cause investigation workflow

1. Identify the failing execution and time window using `systemctl` and `journalctl`.
2. Inspect the application log around the first error, not just the final line.
3. Classify the failure: infrastructure/network, credentials/configuration, source-data issue, transformation bug, destination/write issue, or disk exhaustion.
4. Correlate timestamps in UTC across application logs and journald.
5. Verify the root-cause hypothesis before restarting the service or changing configuration.
6. Document the cause, impact, remediation, and preventive actions.

A restart is a mitigation, not a root-cause analysis.

## Implementation notes and limitations

- The ETL worker is simulated and does not connect to a real database.
- The healthcheck treats `0 rows loaded` as an alert even when the worker exits successfully.
- Log monitoring examines signals from the previous 24 hours.
- Systemd execution history is checked through journald, including recent execution and result information.
- Filesystem usage above 85% is treated as an issue. The healthcheck does not automatically delete files.
- The ETL worker runs under a dedicated unprivileged system account.
- The healthcheck runs as root because it checks system services and reads the protected Telegram configuration.
- Telegram notifications require outbound HTTPS connectivity.
- The ETL service uses `RemainAfterExit=no`. A successful oneshot service returns to the inactive state after execution. The healthcheck therefore uses journald execution history and service result information rather than relying on `systemctl is-active` as proof of a successful run.
- The healthcheck is scheduled one hour after the ETL job. This provides time for the scheduled ETL execution to finish under normal conditions.

## Possible future improvements

- Replace the simulated ETL with actual data processing pipelines connecting to real databases or object storage.
- Add Prometheus/Grafana integration for collecting and visualizing structural execution metrics.
- Implement structured JSON logging inside the Python worker for easier parsing.
- Introduce auto-remediation steps, such as service retries or automatic temporary disk cleanup for non-critical logs.

