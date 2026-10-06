#cloud-config
package_update: true

packages:
  - unzip
  - curl

runcmd:

  # ==============================================================================
  # 1. Настройка параметров безопасности SSH
  # ==============================================================================
  - |
    SSHD_CONF="/etc/ssh/sshd_config"
    
    # HostKeyAlgorithms
    if grep -qE '^#?HostKeyAlgorithms' "$SSHD_CONF"; then
      sed -i -E 's/^#?HostKeyAlgorithms.*/HostKeyAlgorithms +ssh-rsa/' "$SSHD_CONF"
    else
      echo "HostKeyAlgorithms +ssh-rsa" >> "$SSHD_CONF"
    fi

    # PubkeyAcceptedKeyTypes
    if grep -qE '^#?PubkeyAcceptedKeyTypes' "$SSHD_CONF"; then
      sed -i -E 's/^#?PubkeyAcceptedKeyTypes.*/PubkeyAcceptedKeyTypes +ssh-rsa/' "$SSHD_CONF"
    else
      echo "PubkeyAcceptedKeyTypes +ssh-rsa" >> "$SSHD_CONF"
    fi

    # PasswordAuthentication
    if grep -qE '^#?PasswordAuthentication' "$SSHD_CONF"; then
      sed -i -E 's/^#?PasswordAuthentication.*/PasswordAuthentication no/' "$SSHD_CONF"
    else
      echo "PasswordAuthentication no" >> "$SSHD_CONF"
    fi

    systemctl restart ssh || systemctl restart sshd

  # ==============================================================================
  # 2. Скачивание и установка Consul
  # ==============================================================================
  - while systemctl is-active --quiet apt-daily.service apt-daily-upgrade.service; do sleep 2; done
  - while fuser /var/lib/dpkg/lock-frontend >/dev/null 2>&1; do sleep 2; done
  - apt-get update -y
  - apt-get install -y unzip curl

  - curl -fsSL -o /tmp/consul.zip https://storage.yandexcloud.net/my-consul-releases-bucket-2026/consul_2.0.2_linux_amd64.zip
  - unzip /tmp/consul.zip -d /usr/local/bin/
  - chmod +x /usr/local/bin/consul
  - rm -f /tmp/consul.zip

  # Создание пользователя и директорий Consul
  - groupadd --system consul || true
  - useradd --system -g consul --home /etc/consul.d --shell /bin/false consul || true
  - mkdir -p /etc/consul.d /var/lib/consul

  # Генерация основного конфигурационного файла Consul
  - |
    MY_HOSTNAME=$(hostname)
    cat <<EOF > /etc/consul.d/consul.hcl
    datacenter = "${datacenter}"
    data_dir   = "/var/lib/consul"
    log_level  = "INFO"

    bind_addr   = "{{ GetInterfaceIP \"eth0\" }}"
    client_addr = "0.0.0.0"

    retry_join = ${retry_join_ips}

    node_name = "$MY_HOSTNAME"

    server = ${is_server}
    %{ if is_server }
    bootstrap_expect = ${bootstrap_expect}
    ui_config {
      enabled = true
    }
    %{ endif }

    encrypt = "${encrypt_key}"

    addresses {
      http = "0.0.0.0"
      dns  = "0.0.0.0"
    }
    EOF

  # Регистрация сервиса UI в Consul (только для серверов)
  %{ if is_server }
  - |
    cat <<'EOF' > /etc/consul.d/service_consul_ui.json
    {
      "service": {
        "name": "consul",
        "port": 8500,
        "check": {
          "id": "consul-http-check",
          "name": "Consul HTTP Health Check",
          "http": "http://127.0.0.1:8500/v1/status/leader",
          "interval": "10s",
          "timeout": "2s"
        }
      }
    }
    EOF
  %{ endif }

  # Настройка службы systemd для Consul
  - |
    cat <<'EOF' > /etc/systemd/system/consul.service
    [Unit]
    Description="HashiCorp Consul - A service mesh solution"
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
    LimitNOFILE=65536

    [Install]
    WantedBy=multi-user.target
    EOF

  # ==============================================================================
  # 3. Скачивание Node Exporter из S3 и регистрация в Consul
  # ==============================================================================
  - groupadd --system node_exporter || true
  - useradd --system -g node_exporter --no-create-home --shell /bin/false node_exporter || true

  - curl -fsSL -o /tmp/node_exporter.tar.gz https://storage.yandexcloud.net/my-consul-releases-bucket-2026/node_exporter-1.12.1.linux-amd64.tar.gz
  - tar -xvf /tmp/node_exporter.tar.gz -C /tmp/
  - cp /tmp/node_exporter-1.12.1.linux-amd64/node_exporter /usr/local/bin/
  - chmod +x /usr/local/bin/node_exporter
  - rm -rf /tmp/node_exporter*

  # Systemd юнит для Node Exporter
  - |
    cat <<'EOF' > /etc/systemd/system/node_exporter.service
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
    EOF

  # Регистрация Node Exporter как сервиса в Consul
  - |
    cat <<'EOF' > /etc/consul.d/service_node_exporter.json
    {
      "service": {
        "name": "node-exporter",
        "port": 9100,
        "tags": ["monitoring", "prometheus"],
        "check": {
          "id": "node-exporter-check",
          "name": "Node Exporter Health Check",
          "http": "http://127.0.0.1:9100/metrics",
          "interval": "10s",
          "timeout": "2s"
        }
      }
    }
    EOF

  # ==============================================================================
  # 4. Финальная установка прав и запуск служб
  # ==============================================================================
  - chown -R consul:consul /etc/consul.d /var/lib/consul
  - chmod 640 /etc/consul.d/*.json /etc/consul.d/consul.hcl 2>/dev/null || true

  - systemctl daemon-reload
  - systemctl enable consul node_exporter
  - systemctl restart consul node_exporter