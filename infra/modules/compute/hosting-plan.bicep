param name string
param location string = resourceGroup().location
param kind string = 'linux'
@description('Name of the SKU to use for the hosting plan. Use FC1 for Flex Consumption plans or Pxv3 for Premium v3 plans.')
param sku string = 'P0v3'
@description('Defines the hosting plan type. Set to FlexConsumption to provision an FC1 plan or PremiumV3 for Premium v3 plans.')
@allowed([
  'FlexConsumption'
  'PremiumV3'
])
param planType string = 'PremiumV3'
@description('Number of workers to provision for plans that support pre-provisioned capacity. Ignored for Flex Consumption plans.')
param capacity int = 1

@description('Tags.')
param tags object

var normalizedPlanType = toLower(planType)
var isFlexConsumption = normalizedPlanType == 'flexconsumption'
var tier = isFlexConsumption ? 'FlexConsumption' : planType
var skuBase = {
  name: sku
  tier: tier
}
var skuWithCapacity = isFlexConsumption ? skuBase : union(skuBase, {
  capacity: capacity
})

resource hostingPlan 'Microsoft.Web/serverfarms@2024-04-01' = {
  name: name
  location: location
  sku: skuWithCapacity
  properties: {
    reserved: true
  }
  kind: isFlexConsumption ? 'functionapp' : kind
  tags : tags
}

output id string = hostingPlan.id
output name string = hostingPlan.name
output location string = hostingPlan.location
output skuName string = hostingPlan.sku.name
