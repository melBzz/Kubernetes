## Wazuh Configuration — Kubernetes Audit Log Collection
*(Installation and setup details are not covered here, as they are not the focus of this work.)*

Wazuh is deployed in a single-node architecture, on a VM separate from the Kubernetes cluster, hosting the manager, the API, and the indexer. A Wazuh agent is installed on the cluster's control plane; it is configured via the `<localfile>` tag in the `ossec.conf` file:

```
<localfile>
  <log_format>json</log_format>
  <location>/var/log/kubernetes/audit.log</location>
</localfile>
```

This configuration tells the agent to monitor the Kubernetes API server's audit logs. Since these logs are in JSON format, Wazuh uses its native JSON decoder to automatically parse them and extract the relevant fields. A generic rule is then applied, simply matching on every decoded event (`kind=Event`), so that all lines from the audit log are surfaced in the dashboard:

```
<rule id="110000" level="3">
  <decoded_as>json</decoded_as>
  <field name="kind">Event</field>
  <description>Kubernetes Audit: Generic Event</description>
</rule>
```

This baseline rule ensures full visibility of K8s events.