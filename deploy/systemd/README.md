# system_health.sh scheduling

Install and enable (run as root):

    install -m 0755 scripts/system_health.sh /usr/local/bin/system_health.sh
    cp deploy/systemd/system-health.service deploy/systemd/system-health.timer /etc/systemd/system/
    systemctl daemon-reload
    systemctl enable --now system-health.timer

Check:

    systemctl list-timers system-health.timer
    journalctl -u system-health.service -n 20
    tail /var/log/system_health/health_log.txt

Cron alternative (crontab -e):

    */5 * * * * /usr/local/bin/system_health.sh --log-file /var/log/system_health/health_log.txt >/dev/null 2>&1
