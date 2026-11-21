variable "location" {
  type    = string
  default = "swedencentral"
}

variable "prefix" {
  type    = string
  default = "lsevo"
}

variable "suffix" {
  type    = string
  default = "cybersec"
}

variable "aks_vm_size" {
  type    = string
  default = "Standard_D2s_v6"
}

variable "db_admin_login" {
  type    = string
  default = "lsadmin"
}
