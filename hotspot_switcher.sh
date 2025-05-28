#!/bin/bash
set -euo pipefail

# --- Configuration Variables ---
WIFI_INTERFACE="wlp2s0"                   # Replace with your Wi-Fi interface (e.g., wlan0, wlp3s0)
LOG_FILE="/var/log/hotspot_switcher.log"  # Log file for script actions

WIFI_ID="your-home-wifi-ssid"           # Exact name of your main Wi-Fi connection to reconnect to

# Hotspot Configuration via NetworkManager
HOTSPOT_SSID="Hotspot"                  # Name (SSID) your hotspot will display
HOTSPOT_PASSWORD="MyStrongPassword!"    # WPA2 PASSWORD (MINIMUM 8 CHARACTERS, STRONG!)
HOTSPOT_IP="192.168.42.1"               # IP address of the hotspot interface (the router for clients)
HOTSPOT_CON_NAME="hotspot"              # NetworkManager connection name for the hotspot

# --- Functions ---

log_message() {
    echo "$(date '+%Y-%m-%d %H:%M:%S') - $1" | sudo tee -a "$LOG_FILE" > /dev/null
}

# Function to start the hotspot via nmcli with strict WPA2-PSK security.
# The function disables the current WiFi client connection in favor of the hotspot.
start_hotspot_nmcli() {
    log_message "Starting hotspot via NetworkManager: main Wi-Fi will be unavailable."

    # #####
    # 1. Ensure NetworkManager is running and managing the Wi-Fi interface

    # Starts the NetworkManager service. '|| true' ensures the script continues even if NM is already running.
    sudo systemctl start NetworkManager.service || true
    # Ensures NetworkManager manages the specified Wi-Fi interface.
    sudo nmcli dev set "$WIFI_INTERFACE" managed yes
    # Turns on the Wi-Fi radio.
    sudo nmcli radio wifi on
    # Activates NetworkManager's networking capabilities.
    sudo nmcli networking on
    sleep 2 # Give NM a short moment to initialize

    # #####
    # 2. Check if the hotspot profile exists. If not, create it.

    if ! nmcli connection show "$HOTSPOT_CON_NAME" > /dev/null; then
        log_message "Creating hotspot profile '$HOTSPOT_CON_NAME' with strict WPA2 configuration."
        # Creates a new Wi-Fi connection profile for the hotspot.
        # - 'ifname "$WIFI_INTERFACE"' sets the interface name.
        # - 'con-name "$HOTSPOT_CON_NAME"' sets the connection name.
        # - 'autoconnect no' prevents automatic connection at boot.
        # - 'ssid "$HOTSPOT_SSID"' sets the SSID of the hotspot.
        # - '802-11-wireless.mode ap' configures the interface in Access Point mode.
        # - 'ipv4.method shared' enables IP sharing (NAT).
        # - 'ipv4.addresses "$HOTSPOT_IP/24"' sets the IP address and subnet mask for the hotspot.
        sudo nmcli connection add type wifi \
            ifname "$WIFI_INTERFACE" \
            con-name "$HOTSPOT_CON_NAME" \
            autoconnect no \
            ssid "$HOTSPOT_SSID" \
            802-11-wireless.mode ap \
            ipv4.method shared \
            ipv4.addresses "$HOTSPOT_IP/24"

        # Configure strict WPA2-PSK security and disable WPS
        # Modifies the created connection to enforce WPA2-PSK security.
        # - 'wifi-sec.key-mgmt wpa-psk' sets the key management to WPA-PSK.
        # - 'wifi-sec.psk "$HOTSPOT_PASSWORD"' sets the WPA-PSK passphrase.
        # - '802-11-wireless-security.proto rsn' specifies RSN (Robust Security Network), which is WPA2.
        # - '802-11-wireless-security.pairwise ccmp' sets the pairwise cipher to CCMP.
        # - '802-11-wireless-security.group ccmp' sets the group cipher to CCMP.
        # - '802-11-wireless-security.wps-method ""' explicitly disables WPS.
        sudo nmcli connection modify "$HOTSPOT_CON_NAME" \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$HOTSPOT_PASSWORD" \
            802-11-wireless-security.proto rsn \
            802-11-wireless-security.pairwise ccmp \
            802-11-wireless-security.group ccmp \
            802-11-wireless-security.wps-method "" # Indicates not to use WPS
    else
        log_message "Hotspot profile '$HOTSPOT_CON_NAME' already exists. Updating security settings if necessary."
        # If the profile exists, ensure security settings are correct (see above).
        sudo nmcli connection modify "$HOTSPOT_CON_NAME" \
            802-11-wireless.mode ap \
            wifi-sec.key-mgmt wpa-psk \
            wifi-sec.psk "$HOTSPOT_PASSWORD" \
            802-11-wireless-security.proto rsn \
            802-11-wireless-security.pairwise ccmp \
            802-11-wireless-security.group ccmp \
            802-11-wireless-security.wps-method "" # Re-confirms WPS disable
    fi

    # #####
    # 3. Activate the hotspot connection

    log_message "Activating hotspot connection '$HOTSPOT_CON_NAME' on $WIFI_INTERFACE."
    
    # Enable IP forwarding
    echo 1 | sudo tee /proc/sys/net/ipv4/ip_forward > /dev/null
    
    # Configure NAT
    sudo iptables -t nat -F
    sudo iptables -t nat -A POSTROUTING -s 192.168.42.0/24 -j MASQUERADE
    sudo iptables -A FORWARD -i "$WIFI_INTERFACE" -j ACCEPT
    
    # Activate the hotspot
    if sudo nmcli connection up "$HOTSPOT_CON_NAME"; then
        log_message "Hotspot '$HOTSPOT_CON_NAME' started successfully."
        # Verify if the interface is truly in AP mode
        if iw dev "$WIFI_INTERFACE" info | grep -q "type AP"; then
            log_message "Confirmation: Interface $WIFI_INTERFACE is in Access Point mode."
            
            # Set static IP on the interface
            sudo ip addr flush dev "$WIFI_INTERFACE"
            sudo ip addr add 192.168.42.1/24 dev "$WIFI_INTERFACE"
            sudo ip link set "$WIFI_INTERFACE" up
            
            # Start dnsmasq for DHCP
            sudo systemctl stop dnsmasq 2>/dev/null || true
            sudo systemctl start dnsmasq
            
        else
            log_message "WARNING: Interface $WIFI_INTERFACE may not be in AP mode as expected."
        fi
    else
        log_message "ERROR: Failed to start hotspot '$HOTSPOT_CON_NAME'. Check logs and Wi-Fi card compatibility."
    fi
}

# Function to stop the hotspot and reconnect to the main Wi-Fi
stop_hotspot_nmcli() {
    log_message "Main Wi-Fi is back or stop was requested. Stopping hotspot '$HOTSPOT_CON_NAME'."
    
    # Clean up dnsmasq
    log_message "Stopping dnsmasq service..."
    sudo systemctl stop dnsmasq 2>/dev/null || true
    
    # Clean up iptables rules
    log_message "Cleaning up iptables rules..."
    sudo iptables -t nat -D POSTROUTING -s 192.168.42.0/24 -j MASQUERADE 2>/dev/null || true
    sudo iptables -D FORWARD -i "$WIFI_INTERFACE" -j ACCEPT 2>/dev/null || true
    
    # Reset the interface
    log_message "Resetting network interface..."
    sudo ip addr flush dev "$WIFI_INTERFACE" 2>/dev/null || true
    
    # Deactivate the hotspot connection
    log_message "Deactivating hotspot connection..."
    sudo nmcli connection down "$HOTSPOT_CON_NAME" 2>/dev/null || true

    # #####
    # 1. Return the interface to NetworkManager's management and attempt to reconnect to the main Wi-Fi

    log_message "Reverting to NM management and attempting to reconnect to main Wi-Fi ('$WIFI_ID')."
    # Ensures NetworkManager manages the specified Wi-Fi interface.
    sudo nmcli dev set "$WIFI_INTERFACE" managed yes
    # Turns on the Wi-Fi radio.
    sudo nmcli radio wifi on
    # Activates NetworkManager's networking capabilities.
    sudo nmcli networking on
    
    # Reset network interface
    sudo ip link set "$WIFI_INTERFACE" down
    sleep 2
    sudo ip link set "$WIFI_INTERFACE" up
    sleep 5 # Give NM time to stabilize and scan

    # Forces NetworkManager to rescan for Wi-Fi networks.
    sudo nmcli device wifi rescan
    sleep 2

    # #####
    # 2. Attempt to reconnect to the main Wi-Fi network

    # Attempts to bring up the NetworkManager connection for the main Wi-Fi.
    if ! sudo nmcli connection up "$WIFI_ID"; then
        log_message "Failed to directly reconnect to '$WIFI_ID'. Attempting NetworkManager restart."
        # Restarts the entire NetworkManager service in case of reconnection issues.
        sudo systemctl restart NetworkManager
        sleep 10
        # Retries to bring up the main Wi-Fi connection after NetworkManager restart.
        if ! sudo nmcli connection up "$WIFI_ID"; then
            log_message "Persistent failure to reconnect to '$WIFI_ID' after NetworkManager restart. Manual intervention may be needed."
        else
            log_message "Reconnection to '$WIFI_ID' successful after NetworkManager restart."
        fi
    else
        log_message "Reconnection to '$WIFI_ID' successful."
    fi
    log_message "Hotspot stop routine finished."
}

# Function to check the status of the main Wi-Fi connection and act accordingly
# (used for automation)
check_main_wifi_and_act() {
    log_message "Checking main Wi-Fi connection ($WIFI_ID)"

    # Is the main Wi-Fi connected?
    if nmcli -t -f NAME,STATE connection show --active | grep -q "^$WIFI_ID:activated$"; then
        log_message "Main Wi-Fi ('$WIFI_ID') connected."
        # Turn off the hotspot if running.
        if iw dev "$WIFI_INTERFACE" info | grep -q "type AP"; then
            log_message "Stopping hotspot."
            stop_hotspot_nmcli
        fi

    # Are we in hotspot mode?
    elif iw dev "$WIFI_INTERFACE" info | grep -q "type AP"; then
        log_message "Hotspot ('$HOTSPOT_SSID') active."
        # If the main Wi-Fi is available (connectable), stop the hotspot to switch
        if iwlist "$WIFI_INTERFACE" scan 2>/dev/null | grep -q "ESSID:\"$WIFI_ID\""; then
            log_message "Main Wi-Fi ('$WIFI_ID') detected. Stopping hotspot to switch."
            stop_hotspot_nmcli
        fi

    # No active Wi-Fi network on the interface, start the hotspot
    elif ! nmcli -t -f NAME,DEVICE,STATE connection show --active | grep -q ":$WIFI_INTERFACE:activated"; then
        log_message "No active connection on $WIFI_INTERFACE. Starting hotspot."
        start_hotspot_nmcli
    fi
}


# --- Command Line Argument Processing ---
case "${1:-}" in
    start)
        start_hotspot_nmcli
        ;;
    stop)
        stop_hotspot_nmcli
        ;;
    check)
        check_main_wifi_and_act
        ;;
    *)
        # Help if no argument or an invalid argument is provided
        echo "Usage: $0 {start|stop|check}"
        echo "  start: Starts the hotspot."
        echo "  stop: Stops the hotspot and attempts to reconnect to the main Wi-Fi."
        echo "  check: Checks if the main Wi-Fi is connected or is available. If not, starts the hotspot."
        exit 1
        ;;
esac