---
name: vastai-mcp
description: Vast.ai MCP server for renting GPU cloud instances — search GPU offers, create/start/stop/destroy instances, execute commands via SSH, run background training jobs, manage storage volumes, attach SSH keys, and browse templates. Use when the user asks about renting GPUs, Vast.ai instances, GPU cloud compute, running training jobs remotely, or managing cloud GPU infrastructure.
---

# Vast.ai MCP Server — 24 Tools Reference

Configured in `.mcp.json` as `"vast-ai"` (uvx from GitHub). Requires `VAST_API_KEY` in `.env`. SSH tools use `SSH_KEY_FILE` / `SSH_KEY_PUBLIC_FILE` (default: `~/.ssh/id_rsa`).

## Quick Tool Map

| Goal | Tool | Key Params |
|------|------|-----------|
| Account info & balance | `show_user_info` | — |
| List my instances | `show_instances` | `owner` (default: "me") |
| Get one instance's details | `show_instance` | `instance_id` |
| Search GPU offers | `search_offers` | `query`, `limit`, `order` |
| Search storage volumes | `search_volumes` | `query`, `limit` |
| Browse templates | `search_templates` | — |
| **Quick launch** (recommended) | `launch_instance_workflow` | `gpu_name`, `num_gpus`, `image` |
| Create from offer ID | `create_instance` | `offer_id`, `image`, `disk`, `ssh`, `jupyter` |
| Start stopped instance | `start_instance` | `instance_id` |
| Stop running instance | `stop_instance` | `instance_id` |
| Destroy instance | `destroy_instance` | `instance_id` |
| Reboot (keep GPU priority) | `reboot_instance` | `instance_id` |
| Recycle (repull image) | `recycle_instance` | `instance_id` |
| Set instance label | `label_instance` | `instance_id`, `label` |
| Prepay for discount | `prepay_instance` | `instance_id`, `amount` |
| Attach SSH key | `attach_ssh` | `instance_id` |
| Get instance logs | `logs` | `instance_id`, `tail`, `filter_text` |
| Run command (stopped only) | `execute_command` | `instance_id`, `command` |
| Run command via SSH | `ssh_execute_command` | `remote_host`, `remote_user`, `remote_port`, `command` |
| Run background job via SSH | `ssh_execute_background_command` | `remote_host`, `remote_user`, `remote_port`, `command`, `task_name` |
| Check background job | `ssh_check_background_task` | `remote_host`, `remote_user`, `remote_port`, `task_id`, `process_id` |
| Kill background job | `ssh_kill_background_task` | `remote_host`, `remote_user`, `remote_port`, `task_id`, `process_id` |
| Disable sudo password | `disable_sudo_password` | `remote_host`, `remote_user`, `remote_port` |
| View/set automation rules | `configure_mcp_rules` | `auto_attach_ssh`, `auto_label`, `wait_for_ready`, `label_prefix` |

## Query Syntax for `search_offers` / `search_volumes`

Filters use `key=value` pairs separated by spaces. Operators: `=`, `!=`, `>`, `>=`, `<`, `<=`

```
"gpu_name=RTX_4090"                        # Specific GPU model
"gpu_name=RTX_4090 num_gpus=2"             # Dual RTX 4090
"num_gpus>=2 cpu_ram>64 reliability2>=99"  # High-spec, reliable
"dph_total<=1.0"                           # Under $1/hour
"disk_space>=100"                          # 100+ GB storage (volumes)
```

**Sort (`order` param):** append `-` for descending. Default: `"score-"` (best score first). Examples: `"dph_total"` (cheapest first), `"num_gpus-"` (most GPUs first).

## Common Workflows

### 1. Quickest Path: Launch a GPU Instance
```
show_user_info()                           # confirm balance
launch_instance_workflow(
    gpu_name="RTX_4090",
    num_gpus=1,
    image="pytorch/pytorch:latest",
    disk=40.0,
    ssh=True,
    direct=True,
    label="training-job"
)
show_instances()                           # get instance_id + IP/port
```

### 2. Manual Search → Create
```
search_offers("gpu_name=RTX_4090 num_gpus=2", limit=10, order="dph_total")
  → pick offer_id
create_instance(
    offer_id=12345,
    image="pytorch/pytorch:latest",
    disk=50.0, ssh=True, direct=True,
    label="my-training"
)
show_instance(instance_id=67890)           # get IP, SSH port, status
```

### 3. Full ML Training Workflow
```
# Launch instance
launch_instance_workflow(gpu_name="RTX_4090", num_gpus=2,
    image="pytorch/pytorch:latest", disk=50.0, ssh=True)
show_instance(instance_id=67890)           # get remote_host, remote_port

# Setup
ssh_execute_command(remote_host="1.2.3.4", remote_user="root",
    remote_port=26378, command="pip install wandb")

# Start training in background
task = ssh_execute_background_command(
    remote_host="1.2.3.4", remote_user="root", remote_port=26378,
    command="cd /workspace && python train.py --epochs 100",
    task_name="training_run"
)
# Returns task_id and process_id

# Monitor
ssh_check_background_task(remote_host="1.2.3.4", remote_user="root",
    remote_port=26378, task_id="training_run_a1b2c3", process_id=12345)

# Check GPU utilization
ssh_execute_command(remote_host="1.2.3.4", remote_user="root",
    remote_port=26378, command="nvidia-smi")

# Cleanup when done
destroy_instance(instance_id=67890)
```

### 4. Instance Lifecycle Management
```
stop_instance(instance_id=67890)           # pause (preserves disk)
start_instance(instance_id=67890)          # resume
reboot_instance(instance_id=67890)         # restart, keeps GPU priority
recycle_instance(instance_id=67890)        # repull latest image, keeps priority
destroy_instance(instance_id=67890)        # permanently delete
```

### 5. Inspect & Debug a Stopped Instance
```
stop_instance(instance_id=67890)
execute_command(instance_id=67890, command="ls -la /workspace")
execute_command(instance_id=67890, command="du -sh /workspace")
execute_command(instance_id=67890, command="rm -rf /tmp/old_files")
```
Note: `execute_command` only works on stopped instances. Commands limited to `ls`, `rm`, `du`.

### 6. Monitor via Logs
```
logs(instance_id=67890, tail="500")
logs(instance_id=67890, filter_text="error|ERROR", tail="100")
logs(instance_id=67890, daemon_logs=True)  # system/daemon logs
```

### 7. SSH Key & Access Setup
```
attach_ssh(instance_id=67890)              # attaches SSH_KEY_PUBLIC_FILE key
show_instance(instance_id=67890)           # get SSH connection details
ssh_execute_command(remote_host="...", remote_user="root",
    remote_port=..., command="whoami")
```

### 8. Configure Automation Behaviour
```
configure_mcp_rules(
    auto_attach_ssh=True,    # auto-attach SSH key on instance creation
    auto_label=True,         # auto-label instances with timestamp
    wait_for_ready=True,     # wait until "running" after creation
    label_prefix="my-proj"
)
configure_mcp_rules()        # view current rules
```

## Configuration

```
VAST_API_KEY          — Vast.ai API key (console.vast.ai → Account → API Keys)
SSH_KEY_FILE          — Path to SSH private key (default: ~/.ssh/id_rsa)
SSH_KEY_PUBLIC_FILE   — Path to SSH public key (default: ~/.ssh/id_rsa.pub)
```

All loaded automatically at session start via `.env` / `SessionStart` hook.

## Known Behaviors

1. **`launch_instance_workflow`** is the preferred creation path — it runs `search_offers` + `create_instance` in one call, picking the top-scored result.
2. **`execute_command`** only works on stopped instances; limited to `ls`, `rm`, `du` for safety. Use `ssh_execute_command` on running instances instead.
3. **`ssh_execute_background_command`** returns `task_id` and `process_id` — save both for `ssh_check_background_task` / `ssh_kill_background_task`.
4. **`attach_ssh`** reads `SSH_KEY_PUBLIC_FILE`; the key must start with `ssh-` (e.g., `ssh-rsa`, `ssh-ed25519`). Private keys are rejected.
5. **`reboot_instance`** vs **`recycle_instance`**: reboot is stop/start (same image); recycle is destroy/recreate with freshly pulled image — both preserve GPU slot priority.
6. **`prepay_instance`** deposits credits for discounted reserved-instance rates — not applicable to interruptible (bid) instances.
7. **`disable_sudo_password`** backs up `/etc/sudoers`, validates with `visudo -c`, restores on failure — safe to use on fresh instances.
8. **`configure_mcp_rules`** affects `create_instance` and `launch_instance_workflow` behaviour for the session — call with no args to inspect current state.
9. **Bid instances** (`bid_price` param on `create_instance`): cheaper but interruptible — set `bid_price` slightly above market to avoid eviction.
10. **SSH connection info** is in `show_instance` output — look for `public_ipaddr` and the mapped SSH port.
