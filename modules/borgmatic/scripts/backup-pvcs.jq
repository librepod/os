# `kubectl get ns,pvc -A -o json` → "<namespace> <pvc> <volumeName>" per nfs-client PVC to back up;
# a PVC is skipped when it or its Namespace carries backup.libre.pod/disabled=true.
def disabled: .metadata.labels["backup.libre.pod/disabled"] == "true";

[.items[] | select(.kind == "Namespace" and disabled) | .metadata.name] as $skip
| .items[]
| select(.kind == "PersistentVolumeClaim" and .spec.storageClassName == "nfs-client")
| select((disabled | not) and (.metadata.namespace | IN($skip[]) | not))
| "\(.metadata.namespace) \(.metadata.name) \(.spec.volumeName // "")"
