FROM grafana/grafana:latest

COPY datasources/*.yml  /etc/grafana/provisioning/datasources/
COPY dashboards/*.json /var/lib/grafana/dashboards/
COPY dashboards/*.yml /etc/grafana/provisioning/dashboards/
