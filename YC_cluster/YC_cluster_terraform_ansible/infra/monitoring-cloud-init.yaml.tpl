#cloud-config

package_update: false
package_upgrade: false

bootcmd:
  - systemctl stop apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true
  - systemctl disable apt-daily.service apt-daily-upgrade.service unattended-upgrades.service || true
  - systemctl kill --kill-who=all apt-daily.service apt-daily-upgrade.service || true

write_files:
  # ==============================================================================
  # 1. Настройка параметров безопасности SSH
  # ==============================================================================
  - path: /etc/ssh/sshd_config.d/99-custom-security.conf
    owner: root:root
    permissions: "0644"
    content: |
      HostKeyAlgorithms +ssh-rsa
      PubkeyAcceptedKeyTypes +ssh-rsa
      PasswordAuthentication no

  # ==============================================================================
  # 2. Systemd юнит для Consul Agent / Server
  # ==============================================================================
  - path: /etc/systemd/system/consul.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description="HashiCorp Consul Agent"
      Documentation=https://www.consul.io/
      Requires=network-online.target
      After=network-online.target

      [Service]
      User=consul
      Group=consul
      ExecStart=/usr/local/bin/consul agent -config-dir=/etc/consul.d/
      ExecReload=/usr/local/bin/consul reload
      KillMode=process
      Restart=on-failure
      RestartSec=3
      LimitNOFILE=65536

      [Install]
      WantedBy=multi-user.target

  # ==============================================================================
  # 3. Конфигурация Consul Server (monitoring-1)
  # ==============================================================================
  - path: /etc/consul.d/consul.hcl
    owner: root:root
    permissions: "0640"
    content: |
      node_name        = "monitoring-1"
      datacenter       = "${datacenter}"
      data_dir         = "/var/lib/consul"
      log_level        = "INFO"
      server           = false
      bootstrap_expect = ${bootstrap_expect}
      bind_addr        = "{{ GetInterfaceIP \"eth0\" }}"
      client_addr      = "0.0.0.0"
      encrypt          = "${encrypt_key}"
      retry_join       = ${retry_join_ips}

      ui_config {
      enabled = true
      }

  # ==============================================================================
  # 4. Регистрация сервисов в Consul (для Consul Template на HAProxy)
  # ==============================================================================
  - path: /etc/consul.d/service_prometheus.json
    owner: root:root
    permissions: "0640"
    content: |
      {
        "service": {
          "name": "prometheus",
          "tags": ["monitoring", "metrics"],
          "port": 9090,
          "check": {
            "id": "prometheus-http-check",
            "name": "Prometheus Health Check",
            "http": "http://127.0.0.1:9090/-/healthy",
            "interval": "10s",
            "timeout": "2s"
          }
        }
      }

  - path: /etc/consul.d/service_grafana.json
    owner: root:root
    permissions: "0640"
    content: |
      {
        "service": {
          "name": "grafana",
          "tags": ["monitoring", "ui"],
          "port": 3000,
          "check": {
            "id": "grafana-http-check",
            "name": "Grafana Health Check",
            "http": "http://127.0.0.1:3000/api/health",
            "interval": "10s",
            "timeout": "2s"
          }
        }
      }

  - path: /etc/consul.d/service_node_exporter.json
    owner: root:root
    permissions: "0640"
    content: |
      {
        "service": {
          "name": "node-exporter",
          "tags": ["monitoring", "prometheus"],
          "port": 9100,
          "check": {
            "id": "node-exporter-check",
            "name": "Node Exporter Health Check",
            "http": "http://127.0.0.1:9100/metrics",
            "interval": "10s",
            "timeout": "2s"
          }
        }
      }

  # ==============================================================================
  # 5. Systemd юнит для Prometheus
  # ==============================================================================
  - path: /etc/systemd/system/prometheus.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Prometheus
      Wants=network-online.target
      After=network-online.target

      [Service]
      User=prometheus
      Group=prometheus
      Type=simple
      ExecStart=/usr/local/bin/prometheus \
        --config.file=/etc/prometheus/prometheus.yml \
        --storage.tsdb.path=/var/lib/prometheus/ \
        --web.enable-admin-api
      ExecReload=/bin/kill -HUP $MAINPID
      Restart=on-failure

      [Install]
      WantedBy=multi-user.target

  # ==============================================================================
  # 6. Конфигурация Prometheus
  # ==============================================================================
  - path: /etc/prometheus/prometheus.yml
    owner: root:root
    permissions: "0644"
    content: |
      global:
        scrape_interval: 15s

      scrape_configs:
        - job_name: "prometheus"
          static_configs:
            - targets: ["localhost:9090"]

        - job_name: "node_exporter"
          consul_sd_configs:
            - server: '127.0.0.1:8500' # Адрес локального агента Consul
              services: ['node-exporter'] # Имя сервиса, которое вы давали в service_node_exporter.json
          relabel_configs:
            - source_labels: [__meta_consul_node]
              target_label: instance

  # ==============================================================================
  # 7. Systemd юнит для Node Exporter
  # ==============================================================================
  - path: /etc/systemd/system/node_exporter.service
    owner: root:root
    permissions: "0644"
    content: |
      [Unit]
      Description=Node Exporter
      Wants=network-online.target
      After=network-online.target

      [Service]
      User=node_exporter
      Group=node_exporter
      Type=simple
      ExecStart=/usr/local/bin/node_exporter
      Restart=always
      RestartSec=3

      [Install]
      WantedBy=multi-user.target

runcmd:
  # 1. Применение настроек SSH
  - systemctl restart ssh || systemctl restart sshd || true

  # 2. Подготовка APT и разблокировка
  - killall apt apt-get dpkg unattended-upgrade 2>/dev/null || true
  - rm -f /var/lib/apt/lists/lock /var/lib/dpkg/lock-frontend /var/lib/dpkg/lock
  - dpkg --configure -a
  - apt-get update -y
  - DEBIAN_FRONTEND=noninteractive apt-get install -y unzip curl wget gpg musl

  # 3. Создание системных пользователей и групп
  - groupadd --system consul || true
  - useradd --system -g consul --home /etc/consul.d --shell /bin/false consul || true

  - groupadd --system prometheus || true
  - useradd --system -g prometheus --no-create-home --shell /bin/false prometheus || true

  - groupadd --system node_exporter || true
  - useradd --system -g node_exporter --no-create-home --shell /bin/false node_exporter || true

  # 4. Создание директорий и выставление прав на файлы конфигураций
  - mkdir -p /etc/consul.d /var/lib/consul /etc/prometheus /var/lib/prometheus
  - chown -R consul:consul /etc/consul.d /var/lib/consul
  - chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
  - chmod 640 /etc/consul.d/* 2>/dev/null || true
  - chmod 644 /etc/prometheus/prometheus.yml 2>/dev/null || true

  # 5. Установка Consul
  - curl -fsSL -o /tmp/consul.zip https://storage.yandexcloud.net/my-consul-releases-bucket-2026/consul_2.0.2_linux_amd64.zip
  - unzip -o /tmp/consul.zip -d /usr/local/bin/
  - chmod +x /usr/local/bin/consul
  - rm -f /tmp/consul.zip

  # 6. Установка Prometheus
  - mkdir -p /tmp/prometheus
  - curl -fsSL -o /tmp/prometheus/prometheus.tar.gz https://storage.yandexcloud.net/my-consul-releases-bucket-2026/prometheus-3.13.2.linux-amd64.tar.gz
  - tar -xzf /tmp/prometheus/prometheus.tar.gz -C /tmp/prometheus --strip-components=1
  - cp /tmp/prometheus/prometheus /usr/local/bin/
  - cp /tmp/prometheus/promtool /usr/local/bin/
  - chmod +x /usr/local/bin/prometheus /usr/local/bin/promtool
  - rm -rf /tmp/prometheus

  # 7. Установка Node Exporter
  - mkdir -p /tmp/node_exporter
  - curl -fsSL -o /tmp/node_exporter/node_exporter.tar.gz https://storage.yandexcloud.net/my-consul-releases-bucket-2026/node_exporter-1.12.1.linux-amd64.tar.gz
  - tar -xzf /tmp/node_exporter/node_exporter.tar.gz -C /tmp/node_exporter --strip-components=1
  - cp /tmp/node_exporter/node_exporter /usr/local/bin/
  - chmod +x /usr/local/bin/node_exporter
  - rm -rf /tmp/node_exporter

  # 8. Установка Grafana (DEB)
  - mkdir -p /tmp/grafana
  - curl -fsSL -o /tmp/grafana/grafana.deb https://dl.grafana.com/oss/release/grafana_11.5.0_amd64.deb
  - dpkg -i /tmp/grafana/grafana.deb || apt-get install -f -y
  - rm -rf /tmp/grafana

  # 9. Финальная проверка прав и запуск всех сервисов
  - chown -R consul:consul /etc/consul.d /var/lib/consul
  - chown -R prometheus:prometheus /etc/prometheus /var/lib/prometheus
  - chmod 640 /etc/consul.d/*.json /etc/consul.d/*.hcl 2>/dev/null || true

  - systemctl daemon-reload
  - systemctl enable --now grafana-server
  - systemctl enable --now prometheus
  - systemctl enable --now node_exporter
  - systemctl enable --now consul
  - consul reload || systemctl reload consul || true
