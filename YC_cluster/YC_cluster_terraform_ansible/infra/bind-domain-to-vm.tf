variable "yc_cloud_id" {
  type = string
}

variable "yc_folder_id" {
  type = string
}

variable "service_account_id" {
  type = string
}

variable "ssh_key_path" {
  type = string
}

# ==============================================================================
# Получение данных о ранее созданных ресурсах из Yandex Cloud
# ==============================================================================

# Получаем данные о Container Registry по его имени
data "yandex_container_registry" "app_registry" {
  name = "my-app-registry"
}

# Получаем данные о сервисном аккаунте воркера по его имени
data "yandex_iam_service_account" "sa_worker" {
  name = "sa-worker-puller"
}


# ==============================================================================
# Locals
# ==============================================================================
locals {
  bucket_name = "my-consul-releases-bucket-2026"

  consul_server_ips = [
    "192.168.10.10", # IP для сервера в subnet-1 (ru-central1-a)
    "192.168.20.10", # IP для сервера в subnet-2 (ru-central1-b)
    "192.168.30.10"  # IP для сервера в subnet-3 (ru-central1-d)
  ]
}

# ==============================================================================
# Network
# ==============================================================================

resource "yandex_vpc_network" "network" {
  name = "network"
}

resource "yandex_vpc_subnet" "subnet-1" {
  name           = "subnet-1"
  zone           = "ru-central1-a"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.10.0/24"]
}

resource "yandex_vpc_subnet" "subnet-2" {
  name           = "subnet-2"
  zone           = "ru-central1-b"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.20.0/24"]
}

resource "yandex_vpc_subnet" "subnet-3" {
  name           = "subnet-3"
  zone           = "ru-central1-d"
  network_id     = yandex_vpc_network.network.id
  v4_cidr_blocks = ["192.168.30.0/24"]
}

resource "yandex_vpc_security_group" "lb-sg" {
  name        = "lb-security-group"
  description = "Security group for Load Balancers, Consul and Monitoring"
  network_id  = yandex_vpc_network.network.id

    
  ingress {
    protocol       = "ANY"
    description    = "Allow all internal traffic"
    v4_cidr_blocks = [
        "192.168.10.0/24",
        "192.168.20.0/24",
        "192.168.30.0/24"
    ]
  }
  
  ingress {
    protocol          = "TCP"
    description       = "Allow Grafana internal"
    predefined_target = "self_security_group"
    port              = 3000
  }
  
  ingress {
    protocol          = "TCP"
    description       = "Consul HTTP API"
    predefined_target = "self_security_group"
    port              = 8500
  }

  # Consul DNS (если используется внутреннее разрешение имен)

  ingress {
    protocol          = "UDP"
    description       = "Consul DNS UDP"
    predefined_target = "self_security_group"
    port              = 8600
  }
  
  ingress {
    protocol       = "TCP"
    description    = "Allow HTTP for Consul UI / Apps"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 80
  }

    ingress {
    protocol       = "TCP"
    description    = "Allow HTTP for Consul UI / Apps"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 3000
  }

 ingress {
    protocol       = "TCP"
    description    = "Allow HTTP for Consul UI / Apps"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8500
  }


 ingress {
    protocol       = "TCP"
    description    = "Allow HTTP for Consul UI / Apps"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8501
  }

  ingress {
    protocol       = "TCP"
    description    = "Allow Grafana UI"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8080
  }

  ingress {
    protocol       = "TCP"
    description    = "Prometheus test"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 9090
  }

  ingress {
    protocol       = "TCP"
    description    = "Allow SSH"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 22
  }

  ingress {
    protocol       = "TCP"
    description    = "Allow SSH"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 8428
  }

ingress {
    protocol       = "TCP"
    description    = "Allow Elasticsearch API"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 9200
  }

ingress {
    protocol       = "TCP"
    description    = "Allow Kibana UI"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 5601
  }

ingress {
    protocol       = "TCP"
    description    = "Allow Sonarqube"
    v4_cidr_blocks = ["0.0.0.0/0"]
    port           = 9000
}
  # Внутренний трафик кластера (Consul RPC/Serf)
  ingress {
    protocol          = "TCP"
    description       = "Consul RPC"
    predefined_target = "self_security_group"
    port              = 8300
  }

  ingress {
    protocol          = "TCP"
    description       = "Consul RPC"
    predefined_target = "self_security_group"
    port              = 8404
  }

  ingress {
    protocol          = "TCP"
    description       = "Consul Serf LAN TCP"
    predefined_target = "self_security_group"
    port              = 8301
  }

  ingress {
    protocol          = "UDP"
    description       = "Consul Serf LAN UDP"
    predefined_target = "self_security_group"
    port              = 8301
  }

  ingress {
    protocol          = "TCP"
    description       = "Allow Elasticsearch node-to-node"
    predefined_target = "self_security_group"
    port              = 9300
  }


  # Prometheus Scraping (Node Exporter — порт 9100)
  ingress {
    protocol       = "TCP"
    description    = "Node Exporter for Prometheus"
    v4_cidr_blocks = [
      yandex_vpc_subnet.subnet-1.v4_cidr_blocks[0],
      yandex_vpc_subnet.subnet-2.v4_cidr_blocks[0],
      yandex_vpc_subnet.subnet-3.v4_cidr_blocks[0]
    ]
    port           = 9100
  }

  # Исходящий трафик (Разрешаем всё наружу)
  egress {
    protocol       = "ANY"
    description    = "Allow all outbound traffic"
    v4_cidr_blocks = ["0.0.0.0/0"]
    from_port      = 0
    to_port        = 65535
  }
}


# ==============================================================================
# Compute instances: Consul Servers
# ==============================================================================

resource "yandex_compute_instance" "servers" {
  count       = 3
  name        = "server-${count.index}"
  hostname    = "server-${count.index}"
  platform_id = "standard-v3"

  zone = [
    "ru-central1-a",
    "ru-central1-b",
    "ru-central1-d"
  ][count.index]

  labels = {
    consul_server = "true"
  }

  resources {
    cores         = 2
    memory        = 4
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = "fd8clal01mnr2lnop5vr" # ubuntu-2404-lts
      size     = 10
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id = [
      yandex_vpc_subnet.subnet-1.id,
      yandex_vpc_subnet.subnet-2.id,
      yandex_vpc_subnet.subnet-3.id
    ][count.index]
    security_group_ids = [yandex_vpc_security_group.lb-sg.id]

    nat        = true
    ip_address = local.consul_server_ips[count.index]
  }

  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_key_path)}"
    user-data = templatefile("${path.module}/cloud-init.yaml.tpl", {
      datacenter       = "dc1"
      is_server        = "true"
      bootstrap_expect = 3
      encrypt_key      = "cijVdvz5f1bNy4RiR66WkgWYaN/KOVYw8x6NBXomHbg="
      retry_join_ips   = jsonencode(local.consul_server_ips)
      bucket_name      = local.bucket_name
    })
  }
}

# ==============================================================================
# Compute instance: Monitoring Server (Prometheus + Grafana)
# ==============================================================================

resource "yandex_compute_instance" "monitoring" {
  name        = "monitoring-1"
  hostname    = "monitoring-1"
  zone        = "ru-central1-a"
  platform_id = "standard-v3"
  depends_on         = [yandex_compute_instance.servers]
  labels = {
    is_server = "false"
  }

  resources {
    cores         = 2
    memory        = 4
    core_fraction = 20
  }

  boot_disk {
    initialize_params {
      image_id = "fd8clal01mnr2lnop5vr" # Ubuntu 24.04 LTS
      size     = 30
      type     = "network-ssd"
    }
  }

  network_interface {
    subnet_id          = yandex_vpc_subnet.subnet-1.id
    nat                = true
    security_group_ids = [yandex_vpc_security_group.lb-sg.id]
  }

  metadata = {
    ssh-keys  = "ubuntu:${file(var.ssh_key_path)}"
    user-data = templatefile("${path.module}/monitoring-cloud-init.yaml.tpl", {
      datacenter       = "dc1"
      retry_join_ips   = jsonencode(local.consul_server_ips)
      encrypt_key      = "cijVdvz5f1bNy4RiR66WkgWYaN/KOVYw8x6NBXomHbg="
      is_server        = "false"
      bootstrap_expect = 0
      bucket_name      = local.bucket_name
      consul_ver       = "2.0.2"
      prometheus_ver   = "3.13.2"
    })
  }
}

# ==============================================================================
# Compute instance group for workers
# ==============================================================================

resource "yandex_compute_instance_group" "workers" {
  name               = "workers"
  service_account_id = var.service_account_id
  depends_on         = [yandex_compute_instance.servers]

  instance_template {
    name        = "worker-{instance.index}"
    platform_id = "standard-v3"
    service_account_id = data.yandex_iam_service_account.sa_worker.id
    

    resources {
      cores         = 2
      memory        = 2
      core_fraction = 100
    }

    boot_disk {
      initialize_params {
        image_id = "fd8clal01mnr2lnop5vr" # Ubuntu 24.04 LTS
        size     = 20
        type     = "network-hdd"
      }
    }

    network_interface {
      network_id = yandex_vpc_network.network.id
      subnet_ids = [
        yandex_vpc_subnet.subnet-1.id,
        yandex_vpc_subnet.subnet-2.id,
        yandex_vpc_subnet.subnet-3.id,
      ]
      security_group_ids = [yandex_vpc_security_group.lb-sg.id]
      nat                = true
    }

    metadata = {
      ssh-keys  = "ubuntu:${file(var.ssh_key_path)}"
      user-data = templatefile("${path.module}/cloud-init-worker.yaml.tpl", {
        datacenter       = "dc1"
        is_server        = "false"
        bootstrap_expect = 0
        encrypt_key      = "cijVdvz5f1bNy4RiR66WkgWYaN/KOVYw8x6NBXomHbg="
        retry_join_ips   = jsonencode(local.consul_server_ips)
        bucket_name      = local.bucket_name
        registry_url   = "cr.yandex/${data.yandex_container_registry.app_registry.id}"
        consul_template_ver = "0.42.1"
      })
    }

    network_settings {
      type = "STANDARD"
    }
  }

  scale_policy {
    auto_scale {
      initial_size           = 1
      measurement_duration   = 60
      cpu_utilization_target = 90 # Низкий порог для удобства тестирования
      min_zone_size          = 1
      max_size               = 1  # Максимальное количество серверов
      warmup_duration        = 60 # Время на "прогрев" инстанса после старта
    }
  }

  allocation_policy {
    zones = [
      "ru-central1-a",
    ]
  }

  deploy_policy {
    max_unavailable = 1
    max_creating    = 2
    max_expansion   = 1
    max_deleting    = 2
  }
}

# ==============================================================================
# Compute instance group for HAProxy
# ==============================================================================

resource "yandex_compute_instance_group" "haproxy" {
  name               = "haproxy"
  service_account_id = var.service_account_id
  depends_on         = [yandex_compute_instance.servers]

  instance_template {
    name        = "haproxy-{instance.index}"
    platform_id = "standard-v3"

    labels = {
      is_server = "false"
    }

    resources {
      cores         = 2
      memory        = 2
      core_fraction = 20
    }

    boot_disk {
      initialize_params {
        image_id = "fd8clal01mnr2lnop5vr" # Ubuntu 24.04 LTS
        size     = 10
        type     = "network-hdd"
      }
    }

    network_interface {
      network_id         = yandex_vpc_network.network.id
      subnet_ids         = [
        yandex_vpc_subnet.subnet-1.id,
        yandex_vpc_subnet.subnet-2.id,
        yandex_vpc_subnet.subnet-3.id,
      ]
      nat                = true
      security_group_ids = [yandex_vpc_security_group.lb-sg.id]
    }

    metadata = {
      ssh-keys  = "ubuntu:${file(var.ssh_key_path)}"
      user-data = templatefile("${path.module}/cloud-init-haproxy.yaml.tpl", {
        datacenter          = "dc1"
        encrypt_key         = "cijVdvz5f1bNy4RiR66WkgWYaN/KOVYw8x6NBXomHbg="
        retry_join_ips      = jsonencode(local.consul_server_ips)
        bucket_name         = local.bucket_name
        consul_template_ver = "0.42.1"
      })
    }

    network_settings {
      type = "STANDARD"
    }
  }

  scale_policy {
    fixed_scale {
      size = 1
    }
  }

  allocation_policy {
    zones = [
      "ru-central1-a",
      "ru-central1-b",
      "ru-central1-d",
    ]
  }

  deploy_policy {
    max_unavailable = 1
    max_creating    = 1
    max_expansion   = 1
    max_deleting    = 1
  }
}

# ==============================================================================
# Ansible Inventory Generator
# ==============================================================================

resource "terraform_data" "ansible_inventory" {
  depends_on = [
    yandex_compute_instance.servers,
    yandex_compute_instance_group.workers,
    yandex_compute_instance_group.haproxy,
    yandex_compute_instance.monitoring
  ]

  triggers_replace = [
    timestamp()
  ]

  provisioner "local-exec" {
    interpreter = ["PowerShell", "-NoProfile", "-ExecutionPolicy", "Bypass", "-Command"]
    
    # Добавлено поле command, которое записывает переменную окружения в файл inventory.ini
    command     = "Set-Content -Path '${path.module}/inventory.ini' -Value $env:INVENTORY_BODY"

    environment = {
      INVENTORY_BODY = templatefile("${path.module}/inventory.tpl", {
        servers_ips   = yandex_compute_instance.servers[*].network_interface[0].nat_ip_address,
        workers_ips   = yandex_compute_instance_group.workers.instances[*].network_interface[0].nat_ip_address,
        haproxy_ips   = yandex_compute_instance_group.haproxy.instances[*].network_interface[0].nat_ip_address,
        monitoring_ip = yandex_compute_instance.monitoring.network_interface[0].nat_ip_address
      })
    }
  }
}
# ==============================================================================
# Outputs
# ==============================================================================

output "instance_group_servers_public_ips" {
  description = "Public IP addresses for servers"
  value       = yandex_compute_instance.servers[*].network_interface[0].nat_ip_address
}

output "instance_group_workers_public_ips" {
  description = "Public IP addresses for workers"
  value       = yandex_compute_instance_group.workers.instances[*].network_interface[0].nat_ip_address
}

output "instance_group_haproxy_public_ips" {
  description = "Public IP addresses for haproxy"
  value       = yandex_compute_instance_group.haproxy.instances[*].network_interface[0].nat_ip_address
}