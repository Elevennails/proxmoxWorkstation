#!/bin/bash

# Configuration - can be overridden by command line arguments
DEFAULT_VMID="1001"  # Default VM ID
DEFAULT_WIFI_DEVICE="00:14.3"  # Default WiFi card PCI address
DEFAULT_ETHERNET_DEVICE="01:00.0"  # Default Ethernet card PCI address
DEFAULT_HOSTPCI_SLOT="hostpci0"  # Default hostpci slot to use

# Parse command line arguments
VMID="${DEFAULT_VMID}"
WIFI_DEVICE="${DEFAULT_WIFI_DEVICE}"
ETHERNET_DEVICE="${DEFAULT_ETHERNET_DEVICE}"
HOSTPCI_SLOT="${DEFAULT_HOSTPCI_SLOT}"
DEVICE_MODE="both"  # Can be "wifi", "ethernet", or "both"

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Function to check if VM is running
check_vm_status() {
    qm status $VMID | grep -q "running"
    return $?
}

# Function to add PCI devices
add_pci_device() {
    echo -e "${YELLOW}Adding PCI device(s) to VM $VMID...${NC}"
    
    # Check if VM is running
    if check_vm_status; then
        echo -e "${RED}Error: VM $VMID is running. Please shut it down first.${NC}"
        return 1
    fi
    
    local success=0
    
    # Add WiFi device
    if [[ "$DEVICE_MODE" == "wifi" || "$DEVICE_MODE" == "both" ]]; then
        local wifi_slot="hostpci0"
        if qm config $VMID | grep -q "$wifi_slot"; then
            echo -e "${YELLOW}WiFi device already assigned to VM $VMID ($wifi_slot)${NC}"
        else
            if qm set $VMID -$wifi_slot $WIFI_DEVICE,pcie=1; then
                echo -e "${GREEN}Successfully added WiFi device $WIFI_DEVICE to VM $VMID${NC}"
                success=1
            else
                echo -e "${RED}Failed to add WiFi device${NC}"
            fi
        fi
    fi
    
    # Add Ethernet device
    if [[ "$DEVICE_MODE" == "ethernet" || "$DEVICE_MODE" == "both" ]]; then
        local eth_slot="hostpci1"
        if qm config $VMID | grep -q "$eth_slot"; then
            echo -e "${YELLOW}Ethernet device already assigned to VM $VMID ($eth_slot)${NC}"
        else
            if qm set $VMID -$eth_slot $ETHERNET_DEVICE,pcie=1; then
                echo -e "${GREEN}Successfully added Ethernet device $ETHERNET_DEVICE to VM $VMID${NC}"
                success=1
            else
                echo -e "${RED}Failed to add Ethernet device${NC}"
            fi
        fi
    fi
    
    return $([[ $success -eq 1 ]] && echo 0 || echo 1)
}

# Function to remove PCI devices
remove_pci_device() {
    echo -e "${YELLOW}Removing PCI device(s) from VM $VMID...${NC}"
    
    # Check if VM is running
    if check_vm_status; then
        echo -e "${RED}Error: VM $VMID is running. Please shut it down first.${NC}"
        return 1
    fi
    
    local success=0
    
    # Remove WiFi device
    if [[ "$DEVICE_MODE" == "wifi" || "$DEVICE_MODE" == "both" ]]; then
        local wifi_slot="hostpci0"
        if qm config $VMID | grep -q "$wifi_slot"; then
            if qm set $VMID --delete $wifi_slot; then
                echo -e "${GREEN}Successfully removed WiFi device from VM $VMID${NC}"
                success=1
            else
                echo -e "${RED}Failed to remove WiFi device${NC}"
            fi
        else
            echo -e "${YELLOW}No WiFi device assigned to $wifi_slot on VM $VMID${NC}"
        fi
    fi
    
    # Remove Ethernet device
    if [[ "$DEVICE_MODE" == "ethernet" || "$DEVICE_MODE" == "both" ]]; then
        local eth_slot="hostpci1"
        if qm config $VMID | grep -q "$eth_slot"; then
            if qm set $VMID --delete $eth_slot; then
                echo -e "${GREEN}Successfully removed Ethernet device from VM $VMID${NC}"
                success=1
            else
                echo -e "${RED}Failed to remove Ethernet device${NC}"
            fi
        else
            echo -e "${YELLOW}No Ethernet device assigned to $eth_slot on VM $VMID${NC}"
        fi
    fi
    
    return $([[ $success -eq 1 ]] && echo 0 || echo 1)
}

# Function to show current configuration
show_config() {
    echo -e "${YELLOW}Current VM $VMID configuration:${NC}"
    echo "Status: $(qm status $VMID)"
    echo "PCI devices:"
    qm config $VMID | grep -E "^hostpci" || echo "No PCI devices assigned"
}

# Function to toggle PCI devices
toggle_pci_device() {
    local has_wifi=$(qm config $VMID | grep -c "hostpci0")
    local has_ethernet=$(qm config $VMID | grep -c "hostpci1")
    
    if [[ "$DEVICE_MODE" == "both" ]]; then
        if [[ $has_wifi -gt 0 || $has_ethernet -gt 0 ]]; then
            echo -e "${YELLOW}PCI device(s) found, removing...${NC}"
            remove_pci_device
        else
            echo -e "${YELLOW}No PCI devices found, adding...${NC}"
            add_pci_device
        fi
    elif [[ "$DEVICE_MODE" == "wifi" ]]; then
        if [[ $has_wifi -gt 0 ]]; then
            echo -e "${YELLOW}WiFi device found, removing...${NC}"
            remove_pci_device
        else
            echo -e "${YELLOW}No WiFi device found, adding...${NC}"
            add_pci_device
        fi
    elif [[ "$DEVICE_MODE" == "ethernet" ]]; then
        if [[ $has_ethernet -gt 0 ]]; then
            echo -e "${YELLOW}Ethernet device found, removing...${NC}"
            remove_pci_device
        else
            echo -e "${YELLOW}No Ethernet device found, adding...${NC}"
            add_pci_device
        fi
    fi
}

# Parse command line arguments for VM ID and PCI devices
while [[ $# -gt 0 ]]; do
    case $1 in
        --vm|--vmid)
            VMID="$2"
            shift 2
            ;;
        --wifi)
            WIFI_DEVICE="$2"
            shift 2
            ;;
        --ethernet|--eth)
            ETHERNET_DEVICE="$2"
            shift 2
            ;;
        --slot)
            HOSTPCI_SLOT="$2"
            shift 2
            ;;
        --device-mode|--mode)
            DEVICE_MODE="$2"
            shift 2
            ;;
        -*)
            echo "Unknown option $1"
            exit 1
            ;;
        *)
            # This is the command
            COMMAND="$1"
            shift
            break
            ;;
    esac
done

# Use the command from parsing or the first remaining argument
COMMAND="${COMMAND:-$1}"

# Main script logic
case "${COMMAND:-}" in
    "add"|"attach")
        add_pci_device
        ;;
    "remove"|"detach")
        remove_pci_device
        ;;
    "toggle")
        toggle_pci_device
        ;;
    "status"|"show")
        show_config
        ;;
    "start")
        echo -e "${YELLOW}Starting VM $VMID...${NC}"
        qm start $VMID
        ;;
    "stop")
        echo -e "${YELLOW}Stopping VM $VMID...${NC}"
        qm stop $VMID
        ;;
    "restart")
        echo -e "${YELLOW}Restarting VM $VMID...${NC}"
        qm stop $VMID
        sleep 3
        qm start $VMID
        ;;
    *)
        echo "Usage: $0 [OPTIONS] {add|remove|toggle|status|start|stop|restart}"
        echo ""
        echo "Options:"
        echo "  --vm, --vmid ID        VM ID (default: $DEFAULT_VMID)"
        echo "  --wifi ID              WiFi PCI device address (default: $DEFAULT_WIFI_DEVICE)"
        echo "  --ethernet, --eth ID   Ethernet PCI device address (default: $DEFAULT_ETHERNET_DEVICE)"
        echo "  --mode MODE            Device mode: wifi, ethernet, or both (default: both)"
        echo ""
        echo "Commands:"
        echo "  add/attach  - Add PCI device(s) to VM"
        echo "  remove/detach - Remove PCI device(s) from VM"
        echo "  toggle      - Add if not present, remove if present"
        echo "  status/show - Show current VM configuration"
        echo "  start       - Start the VM"
        echo "  stop        - Stop the VM"
        echo "  restart     - Restart the VM"
        echo ""
        echo "Examples:"
        echo "  $0 --vm 101 add                    # Add both WiFi and Ethernet"
        echo "  $0 --vm 101 --mode wifi add        # Add only WiFi"
        echo "  $0 --vm 101 --mode ethernet add    # Add only Ethernet"
        echo "  $0 --wifi 02:00.0 --eth 03:00.0 add"
        echo "  $0 --vm 102 remove"
        echo ""
        echo "Current configuration (VM $VMID, Mode: $DEVICE_MODE):"
        echo "WiFi: $WIFI_DEVICE, Ethernet: $ETHERNET_DEVICE"
        show_config
        exit 1
        ;;
esac
