#!/bin/bash
# Cleanup script to delete NAT Gateway and recreate
# Run this from Azure Cloud Shell or with Azure CLI

echo "======================================"
echo "NAT Gateway Cleanup Script"
echo "======================================"
echo ""
echo "This script will help you delete and recreate the NAT Gateway"
echo ""

RESOURCE_GROUP="${1:-testpatroni2}"
NAT_GATEWAY_NAME="pgpatroni-nat"
PUBLIC_IP_NAME="pgpatroni-nat-pip"

echo "Resource Group: $RESOURCE_GROUP"
echo "NAT Gateway: $NAT_GATEWAY_NAME"
echo "Public IP: $PUBLIC_IP_NAME"
echo ""
echo "Steps to fix:"
echo ""
echo "1. Delete NAT Gateway (it will be recreated by template):"
echo "   az network nat gateway delete --name $NAT_GATEWAY_NAME --resource-group $RESOURCE_GROUP"
echo ""
echo "2. Optionally delete Public IP (will be recreated):"
echo "   az network public-ip delete --name $PUBLIC_IP_NAME --resource-group $RESOURCE_GROUP"
echo ""
echo "3. Then redeploy using the template"
echo ""
echo "Or delete the entire resource group and redeploy:"
echo "   az group delete --name $RESOURCE_GROUP --yes --no-wait"
echo ""

