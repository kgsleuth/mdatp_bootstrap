#!/usr/bin/env bash

# Script Name: bootstrap-syslog-enhanced.sh
# Description: This Bash script automates the configuration of various aspects
#              of a Linux system, focusing on logging, security, and service
#              management. It sets up log rotation, rsyslog, SELinux, firewall,
#              and other configurations to ensure efficient and secure operation
#              of the system.

# Corporate Use License:
#   This script is provided "as is", without warranty of any kind, express or implied, 
#   and is intended for use by Stream Datacenters employees or systems only. Unauthorized 
#   use, distribution, or modification outside of Stream Datacenters is strictly prohibited. 

# This script performs several administrative tasks to secure and manage logging on a Linux server:
#   - Ensures the script is run with root privileges for necessary permissions
#   - Updates the system and installs Python3 for script dependencies
#   - Configures SELinux to allow rsyslog traffic on specific ports
#   - Adjusts the firewall settings to permit rsyslog traffic
#   - Installs rsyslog and rsyslog-gnutls 
#   - Sets up a custom logrotate configuration for efficient log management
#   - Configures Azure Sentinel connector if required ports are not listening

## Imports
# Download common.sh
download_file() {
  # This function takes two arguments: the URL to download and the output file path.
  # It will attempt to download the file up to 5 times, waiting 5 seconds between
  # each attempt. If the download fails after 5 attempts, the function returns 1.

    local url=$1
    local output=$2
    local retries=5
    local wait=5

    for ((i=1; i<=retries; i++)); do
        if curl -o "$output" "$url"; then
            echo "Download succeeded on attempt $i."
            return 0
        else
            echo "Download failed on attempt $i. Retrying in $wait seconds..."
            sleep $wait
        fi
    done

    echo "Download failed after $retries attempts."
    return 1
}

# Create directory if it doesn't exist
mkdir -p lib

# Download common.sh with retries
if ! download_file "https://raw.githubusercontent.com/kgsleuth/scripts/main/lib/common.sh" "lib/common.sh"; then
    echo "Failed to download common.sh. Exiting."
    exit 1
fi

# Source the common.sh file
source lib/common.sh

# Define global variables for the logrotate configuration file and the log file

## Variables for certificate subject fields
# Certificate subject fields for generating SSL certificatesCOUNTRY="US"
STATE="California"
CITY="San Francisco"
ORGANIZATION="Azure" ## west-us-3
COMMON_NAME="stream-dc.com"

## Default paths for self-signed certificates
CA_CERT="${CA_CERT:-/etc/ssl/certs/rsyslog-ca-cert.pem}"
SERVER_CERT="${SERVER_CERT:-/etc/ssl/certs/rsyslog-server-cert.pem}"
SERVER_KEY="${SERVER_KEY:-/etc/ssl/private/rsyslog-server-key.pem}"

## Log rotation configuration content
LOGROTATE_CONF_DIR="/etc/logrotate.d"
LOGROTATE_CONF_PATH="$LOGROTATE_CONF_DIR/all_logs"
LOGROTATE_CONF=$(cat <<'EOF'
## Log rotation configuration content

# This logrotate configuration defines rotation settings for all logs on the
# host. It rotates logs located in /var/log and its subdirectories, keeping
# three rotated copies and rotating logs daily. If a log file exceeds 100
# megabytes or the total log size surpasses 20 gigabytes, it triggers rotation.
# Rotated logs are compressed, and compression is delayed until the next
# rotation. The configuration handles missing and empty logs gracefully, sets
# ownership and permissions for new log files, and runs postrotate scripts for
# additional actions such as rotating syslog logs and deleting older logs if the
# total size exceeds the limit or if logs are older than three days.

# Rotate all logs in /var/log and its subdirectories
/var/log/* /var/log/*/* {
    rotate 3
    daily
    size 100M
    total size 20G
    compress
    delaycompress
    missingok
    notifempty
    create 0640 root adm
    sharedscripts
    # postrotate
    #     /usr/sbin/logrotate /etc/logrotate.conf
    #     total_size=$(du -sh /var/log | cut -f1)
    #     if [ "$(echo "$total_size > 20G" | bc)" -eq 1 ]; then
    #         echo "Total log size exceeds 20 gigabytes. Deleting older logs..."
    #         find /var/log -type f -mtime +3 -exec rm {} \;
    #     fi
    # endscript
}
EOF
)


# Rsyslog configuration paths
RSYSLOG_CONF_DIR="/etc/rsyslog.d"
RSYSLOG_CONF_PATH="$RSYSLOG_CONF_DIR/50-rsyslog-normal.conf"
RSYSLOG_TLS_CONF_PATH="$RSYSLOG_CONF_DIR/99-rsyslog-tls.conf"


# Define normal syslog configuration for port 514 (UDP and TCP)
RSYSLOG_CONF=$(cat <<EOF
# Config loads UDP/TCP modules once to avoid duplicates. It sets inputs for
# UDP/TCP (incl. TLS) on designated ports. Dynamic template for log filenames
# uses hostname/program. A unified ruleset processes all messages, streamlining
# syslog handling, improving management, security, and log organization.

## Load modules for UDP/TCP syslog. Ensures no duplicate module loading.
module(load="imudp") # For UDP
module(load="imtcp") # For TCP & TLS

## Define UDP input on port 514 for syslog messages.
input(type="imudp" port="514" address="0.0.0.0" ruleset="remoteLogs")

# Define TCP input on port 514 for non-TLS syslog.
input(type="imtcp" port="514" address="0.0.0.0" ruleset="remoteLogs")


# Define TCP input on port 6514 for TLS-encrypted syslog.
input(type="imtcp" port="6514" address="0.0.0.0" ruleset="remoteLogs")


# Template for dynamic log file naming based on hostname and program.
template(name="RemoteLogFileName" type="string" 
         string="/var/log/%HOSTNAME%/%PROGRAMNAME%.log")

# Ruleset for processing all syslog messages.
# Applies unified processing for both standard and encrypted logs.
ruleset(name="remoteLogs") {
    action(type="omfile" DynaFile="RemoteLogFileName")
}

# This configuration streamlines syslog processing, ensuring efficient
# log management and facilitating secure, organized storage of log data.

# # Set the logging level to "warning" to filter out lower severity messages
# # such as informational and debug messages, leaving only warning and error messages.
# $LogLevel warning

EOF
)


# Secure syslog  configuration content
RSYSLOG_TLS_CONF=$(cat <<'EOF'
# Load necessary modules for TCP syslog messages and TCP syslog messages with TLS
# encryption. Define input for TCP syslog messages with TLS encryption on port
# 6514. Specify a template for log file names, indicating the directory path and
# placeholders for hostname and program name. Establish a ruleset named
# "remoteLogs" for processing incoming syslog messages, directing the system to
# log messages to a file specified by the defined template.

# Define TLS settings for syslog
$DefaultNetstreamDriver gtls
$DefaultNetstreamDriverCAFile /etc/ssl/certs/rsyslog-ca-cert.pem
$DefaultNetstreamDriverCertFile /etc/ssl/certs/rsyslog-server-cert.pem
$DefaultNetstreamDriverKeyFile /etc/ssl/private/rsyslog-server-key.pem
# $ActionSendStreamDriverAuthMode x509/name
# $ActionSendStreamDriverPermittedPeer *.stream-dc.com

EOF
)


main(){
    # Define local variables for the azure workspace and secret

    usage

    log --info "Script execution started."

    packages=( python3 policycoreutils-python-utils rsyslog rsyslog-gnutls )

    log --info "Updating the host and installing required packages"
    upm --update
    log --info "Install necessary dependencies..."
    upm --install "${packages[@]}"
    log --info "Freeing up space and removing outdated packages by clearing the package manager cache"
    upm --clean

    setenforce 0

    log --info "Generating a self-signed certificate for TLS if none is provided, ensuring secure communication for syslog over TLS"
    generate_tls_certificates

    [ ! -f "/.dockerenv" ] && log --info "Installing the Azure Monitor Agent" || log --info "Skipping AMA Install, in staging environment"
    [ ! -f "/.dockerenv" ] && install_ama_agent

    log --info "Configure syslog services for log rotation and secure reception."
    config_builder "$LOGROTATE_CONF_PATH"       "$LOGROTATE_CONF"   "Custom logrotate"
    config_builder "$RSYSLOG_CONF_PATH"         "$RSYSLOG_CONF"     "Normal log reception"
    config_builder "$RSYSLOG_TLS_CONF_PATH"     "$RSYSLOG_TLS_CONF" "Secure log reception"

    log --info "Enabling and starting firewall service"
    configure_firewall  --enable
    configure_firewall  --start

    log --info "Setting firewall to drop all inbound connections."
    configure_firewall  --drop-all

    log --info "Configuring syslog reviecer ports."
    configure_firewall  --port 514  --protocol udp
    configure_firewall  --port 514  --protocol tcp
    configure_firewall  --port 6514 --protocol tcp

    log --info "Loading new configurations"
    configure_firewall  --reload

    log --info "Restart necessary services to apply the new configurations."
    systemctl restart firewalld
    systemctl restart rsyslog

    log --info "Creating a CRON job to delete logs older than 3 days."
    add_cron_job_if_not_exists --cron-string "0 */4 * * *" \
                               --command "/usr/bin/find /var/log -type f -mtime +3 -exec rm -f {} \;"


    log --info "Creating a CRON job to update the host at 2 am nightly."
    add_cron_job_if_not_exists --cron-string "0 2 * * *" \
                               --command "/usr/bin/dnf -y update --refresh && /usr/bin/dnf -y upgrade && /usr/bin/dnf clean all >> /var/log/dnf-cron.log 2>&1"
    
    systemctl enable crond
    systemctl start crond

    log --info "Configuring security profiles for SELinux."
    configure_selinux --bootstrap

    log --info "Script execution completed."
}


# This is the entry point of the script, and checks if both azure_workspace and secret_key variables are provided
main
