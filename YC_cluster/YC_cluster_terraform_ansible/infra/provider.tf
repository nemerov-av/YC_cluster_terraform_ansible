terraform {
  required_providers {
    yandex = {
      source  = "yandex-cloud/yandex"
      version = ">=0.75.0"
    }
  }
}

provider "yandex" {
  service_account_key_file = "authorized_key.json"
  cloud_id  = var.yc_cloud_id
  folder_id = var.yc_folder_id
}