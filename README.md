# dmz

There are two vm `web-vm` and `internal-vm`.

```
sudo bash host_prereqs.sh
```

```
sudo bash host_setup.sh
```

```
sudo VERBOSE=1 WAIT_SSH=0 DEBUG_CLOUDINIT=1 bash provision_dmv_stack.sh all
```

## TS

### How to reset

```
sudo bash factory-reset.sh && sudo bash host_setup.sh
```

```
sudo VERBOSE=1 WAIT_SSH=0 DEBUG_CLOUDINIT=1 bash provision_dmv_stack.sh all
```

### How to install packages

```
sudo bash provision_dmv_stack.sh egress-on
```

```
sudo virsh console internal-vm
```

Then installing some tools,

```
sudo bash provision_dmv_stack.sh egress-off
```