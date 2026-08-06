targetScope = 'resourceGroup'

param location string = resourceGroup().location

output deploymentLocation string = location
