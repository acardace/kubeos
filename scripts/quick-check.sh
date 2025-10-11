#!/bin/bash
# Quick cluster health check

echo "=== Quick Cluster Check ==="
echo ""
echo "Node Status:"
kubectl get nodes -o wide
echo ""
echo "System Pods:"
kubectl -n kube-system get pods -o wide
echo ""
echo "Cluster Info:"
kubectl cluster-info
echo ""
echo "Component Status:"
kubectl get cs 2>/dev/null || echo "(component status deprecated in 1.19+)"
echo ""
echo "Node IP:"
ip addr show vlan2 | grep "inet " || echo "No vlan2 interface"
echo ""
echo "Services:"
systemctl status kubelet --no-pager -l | head -5
systemctl status crio --no-pager -l | head -5
echo ""
echo "To run full verification:"
echo "  sudo /usr/local/bin/verify-cluster.sh"
