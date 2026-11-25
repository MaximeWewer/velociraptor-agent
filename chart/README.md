# velociraptor-agent chart

Velociraptor agent as a DaemonSet: one client per node, host processes (hostPID), host
filesystem (read-only `/host`, remapped to `/`), every container through `/proc/<pid>/root`.

See the [repository README](../README.md) for the deployment model, security profiles,
artifacts and the security implications. All values are documented in [values.yaml](values.yaml).

```bash
helm install agent oci://ghcr.io/maximewewer/charts/velociraptor-agent --devel -n velociraptor \
  --set clientConfig.existingSecret=velo-velociraptor-client-root
```
