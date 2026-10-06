[consul_servers]
%{ for idx, ip in servers_ips ~}
consul-srv-${idx + 1} ansible_host=${ip} consul_node_role=server
%{ endfor ~}

[load_balancers]
%{ for idx, ip in haproxy_ips ~}
lb-${format("%02d", idx + 1)} ansible_host=${ip} consul_node_role=client
%{ endfor ~}

[monitoring]
monitoring-1 ansible_host=${monitoring_ip} consul_node_role=client

%{ if length(workers_ips) > 0 ~}
[backends]
%{ for idx, ip in workers_ips ~}
backend-v${idx + 1} ansible_host=${ip} consul_node_role=client
%{ endfor ~}

[consul_clients:children]
backends
load_balancers
monitoring
%{ else ~}
[consul_clients:children]
load_balancers
monitoring
%{ endif ~}

[elastic_nodes]
%{ for idx, ip in servers_ips ~}
consul-srv-${idx + 1} ansible_host=${ip} consul_node_role=server
%{ endfor ~}

[kibana]
monitoring-1 ansible_host=${monitoring_ip} consul_node_role=client

[log_clients:children]
load_balancers
monitoring
backends


[all:vars]
ansible_user=ubuntu
ansible_python_interpreter=/usr/bin/python3
ansible_ssh_common_args='-o StrictHostKeyChecking=no'