---
apiVersion: v1alpha1
kind: LinkAliasConfig
name: ethSel0
selector:
  match: glob("{{ .Node.Data.macAddr }}", mac(link.hardware_addr))
---
apiVersion: v1alpha1
kind: BondConfig
name: bond0
links:
  - ethSel0
bondMode: active-backup
mtu: {{ .Node.Data.mtu }}
addresses:
  - address: "{{ .Node.IP }}/24"
routes:
  - gateway: "10.26.10.1"
{{- if eq .Node.Role "control-plane" }}
---
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.99
vlanID: 99
parent: bond0
mtu: 9000
---
apiVersion: v1alpha1
kind: VLANConfig
name: bond0.50
vlanID: 50
parent: bond0
mtu: 9000
---
apiVersion: v1alpha1
kind: Layer2VIPConfig
link: bond0
name: "10.26.10.100"
{{- end }}
