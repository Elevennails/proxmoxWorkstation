#!/bin/bash
sudo ip link set vmbr0 down
sudo ip link set enxec750c2e8e25 down
sleep 10
sudo ip link set enxec750c2e8e25 up
sleep 10
sudo ip link set vmbr0 up
