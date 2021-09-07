terraform {
  required_version = ">= 0.12"
}

provider "azurerm" {
  version = "~>2.75"
  features {}
}
locals {
  solution_name      = "aksprivatemvp"
  dns_service_ip     = "10.11.4.10"
  docker_bridge_cidr = "172.17.0.1/16"
  pod_cidr           = "10.244.0.0/16"
  service_cidr       = "10.11.4.0/24"

}
resource "azurerm_resource_group" "this" {
  name     = "${local.solution_name}-rg"
  location = "West Europe"
}

resource "azurerm_virtual_network" "this" {
  name                = "${local.solution_name}-infrastructure-vnet"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  address_space       = ["10.11.0.0/16"]

  tags = {
    source = "Terrafrom"
  }
}

resource "azurerm_subnet" "aks_node_pool" {
  name                                           = "AKSNodePoolSubnet"
  resource_group_name                            = azurerm_resource_group.this.name
  virtual_network_name                           = azurerm_virtual_network.this.name
  enforce_private_link_endpoint_network_policies = true
  address_prefixes                               = ["10.11.6.0/23"]
}

resource "azurerm_network_interface" "this" {
  name                = "${local.solution_name}-jumphost-nic"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                          = "internal"
    subnet_id                     = azurerm_subnet.aks_node_pool.id
    private_ip_address_allocation = "Dynamic"
  }
}

resource "azurerm_linux_virtual_machine" "jumphost" {
  name                = "${local.solution_name}-jumphost"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
  size                = "Standard_F2"
  admin_username      = "abb1mvpadmin"
  network_interface_ids = [
    azurerm_network_interface.this.id,
  ]

  admin_ssh_key {
    username   = "abb1mvpadmin"
    public_key = file("~/.ssh/id_rsa.pub")
  }

  os_disk {
    caching              = "ReadWrite"
    storage_account_type = "Standard_LRS"
  }

  source_image_reference {
    publisher = "Canonical"
    offer     = "UbuntuServer"
    sku       = "18.04-LTS"
    version   = "latest"
  }
}
resource "azurerm_private_dns_zone" "this" {
  name                = "privatelink.westeurope.azmk8s.io"
  resource_group_name = azurerm_resource_group.this.name
}

resource "azurerm_user_assigned_identity" "this" {
  name                = "aks-${local.solution_name}-identity"
  resource_group_name = azurerm_resource_group.this.name
  location            = azurerm_resource_group.this.location
}

resource "azurerm_role_assignment" "aks_private_dns_zone_contributor_role_assignment" {
  scope                = azurerm_private_dns_zone.this.id
  role_definition_name = "Private DNS Zone Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_role_assignment" "aks_network_contributor_role_assignment" {
  scope                = azurerm_virtual_network.this.id
  role_definition_name = "Network Contributor"
  principal_id         = azurerm_user_assigned_identity.this.principal_id
}

resource "azurerm_kubernetes_cluster" "this" {
  name                    = "aks-${local.solution_name}"
  location                = azurerm_resource_group.this.location
  resource_group_name     = azurerm_resource_group.this.name
  dns_prefix              = "aks${local.solution_name}"
  node_resource_group     = "aks-${local.solution_name}-nodes"
  private_cluster_enabled = true
  private_dns_zone_id     = azurerm_private_dns_zone.this.id

  default_node_pool {
    name           = "default"
    node_count     = 1
    vm_size        = "Standard_D2_v2"
    vnet_subnet_id = azurerm_subnet.aks_node_pool.id
  }

  network_profile {
    network_plugin     = "kubenet"
    dns_service_ip     = local.dns_service_ip
    docker_bridge_cidr = local.docker_bridge_cidr
    pod_cidr           = local.pod_cidr
    service_cidr       = local.service_cidr
    load_balancer_sku  = "Standard"
  }

  identity {
    type                      = "UserAssigned"
    user_assigned_identity_id = azurerm_user_assigned_identity.this.id
  }

  tags = {
    source = "Teraform"
  }

  depends_on = [
    azurerm_role_assignment.aks_private_dns_zone_contributor_role_assignment,
    azurerm_role_assignment.aks_network_contributor_role_assignment,
  ]
}

output "client_certificate" {
  value = azurerm_kubernetes_cluster.this.kube_config.0.client_certificate
}

output "kube_config" {
  value = azurerm_kubernetes_cluster.this.kube_config_raw

  sensitive = true
}

resource "azurerm_subnet" "azure_bastion_subnet" {
  name                 = "AzureBastionSubnet"
  resource_group_name  = azurerm_resource_group.this.name
  virtual_network_name = azurerm_virtual_network.this.name
  address_prefixes     = ["10.11.8.0/27"]
}

resource "azurerm_public_ip" "azure_bastion_public_ip" {
  name                = "${local.solution_name}-AzureBastionPublicIP"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name
  allocation_method   = "Static"
  sku                 = "Standard"
}

resource "azurerm_bastion_host" "azure_bastion" {
  name                = "${local.solution_name}-azure_bastion"
  location            = azurerm_resource_group.this.location
  resource_group_name = azurerm_resource_group.this.name

  ip_configuration {
    name                 = "configuration"
    subnet_id            = azurerm_subnet.azure_bastion_subnet.id
    public_ip_address_id = azurerm_public_ip.azure_bastion_public_ip.id
  }
}