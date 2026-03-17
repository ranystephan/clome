#!/usr/bin/env python3
"""
Clome Kernel Bridge — wraps jupyter_client for kernel execution.
Reads newline-delimited JSON commands from stdin, writes JSON output lines to stdout.
"""

import json
import sys
import uuid
import threading
import atexit
import queue as queue_mod

def send(obj):
    sys.stdout.write(json.dumps(obj) + "\n")
    sys.stdout.flush()

try:
    import jupyter_client
except ImportError:
    send({
        "type": "error",
        "message": "jupyter_client not available in this Python environment. "
                   "Clome should auto-provision a venv — if you see this, "
                   "try restarting the notebook or check ~/Library/Application Support/Clome/kernel-venv/"
    })
    sys.exit(1)

send({"type": "ready"})

km = None  # KernelManager
kc = None  # KernelClient
execute_lock = threading.Lock()
kernel_state_lock = threading.Lock()


def list_kernels():
    specs = jupyter_client.kernelspec.find_kernel_specs()
    kernels = []
    for name, path in specs.items():
        try:
            spec = jupyter_client.kernelspec.get_kernel_spec(name)
            kernels.append({
                "name": name,
                "display_name": spec.display_name,
                "language": getattr(spec, "language", name),
            })
        except Exception:
            kernels.append({"name": name, "display_name": name, "language": name})
    send({"type": "response", "action": "list_kernels", "kernels": kernels})


def start_kernel(kernel_name):
    global km, kc
    with kernel_state_lock:
        with execute_lock:
            try:
                if km is not None:
                    try:
                        km.shutdown_kernel(now=True)
                    except Exception as e:
                        send({"type": "error", "message": f"Failed to shut down previous kernel: {e}"})
                km = jupyter_client.KernelManager(kernel_name=kernel_name)
                km.start_kernel()
                kc = km.client()
                kc.start_channels()
                try:
                    kc.wait_for_ready(timeout=30)
                except Exception as e:
                    send({"type": "error", "message": f"Kernel ready timeout: {e}"})
                send({"type": "response", "action": "start_kernel", "status": "ok"})
            except Exception as e:
                send({"type": "response", "action": "start_kernel", "status": "error", "message": str(e)})


def execute_code(code, exec_id):
    # Capture kc reference under kernel_state_lock
    with kernel_state_lock:
        local_kc = kc
    if local_kc is None:
        send({"type": "complete", "exec_id": exec_id, "status": "error",
              "message": "No kernel running"})
        return

    with execute_lock:
        msg_id = local_kc.execute(code)
        while True:
            try:
                msg = local_kc.get_iopub_msg(timeout=1.0)
            except queue_mod.Empty:
                continue
            except Exception as e:
                send({"type": "error", "message": f"iopub error: {e}"})
                continue

            msg_type = msg["msg_type"]
            parent_id = msg.get("parent_header", {}).get("msg_id", "")
            if parent_id != msg_id:
                continue

            content = msg.get("content", {})

            if msg_type == "stream":
                send({
                    "type": "output", "exec_id": exec_id,
                    "msg_type": "stream",
                    "name": content.get("name", "stdout"),
                    "text": content.get("text", ""),
                })
            elif msg_type in ("execute_result", "display_data"):
                data = content.get("data", {})
                output = {
                    "type": "output", "exec_id": exec_id,
                    "msg_type": msg_type,
                }
                if "text/plain" in data:
                    output["text_plain"] = data["text/plain"]
                if "text/html" in data:
                    output["text_html"] = data["text/html"]
                if "image/png" in data:
                    output["image_png"] = data["image/png"]
                if "image/jpeg" in data:
                    output["image_jpeg"] = data["image/jpeg"]
                if "image/svg+xml" in data:
                    output["image_svg"] = data["image/svg+xml"]
                if msg_type == "execute_result":
                    output["execution_count"] = content.get("execution_count")
                send(output)
            elif msg_type == "error":
                send({
                    "type": "output", "exec_id": exec_id,
                    "msg_type": "error",
                    "ename": content.get("ename", ""),
                    "evalue": content.get("evalue", ""),
                    "traceback": content.get("traceback", []),
                })
            elif msg_type == "status":
                if content.get("execution_state") == "idle":
                    break

        # Get the execute_reply for execution_count and status
        try:
            reply = local_kc.get_shell_msg(timeout=5.0)
            reply_content = reply.get("content", {})
            send({
                "type": "complete", "exec_id": exec_id,
                "execution_count": reply_content.get("execution_count"),
                "status": reply_content.get("status", "ok"),
            })
        except Exception as e:
            send({"type": "complete", "exec_id": exec_id, "status": "ok",
                  "message": f"Shell reply timeout: {e}"})


def interrupt_kernel():
    global km
    if km is not None:
        try:
            km.interrupt_kernel()
        except Exception:
            pass
    send({"type": "response", "action": "interrupt", "status": "ok"})


def restart_kernel():
    global km, kc
    with kernel_state_lock:
        with execute_lock:
            if km is not None:
                try:
                    km.restart_kernel()
                    kc = km.client()
                    kc.start_channels()
                    try:
                        kc.wait_for_ready(timeout=30)
                    except Exception as e:
                        send({"type": "error", "message": f"Kernel ready timeout after restart: {e}"})
                except Exception as e:
                    send({"type": "response", "action": "restart", "status": "error", "message": str(e)})
                    return
    send({"type": "response", "action": "restart", "status": "ok"})


def shutdown_kernel():
    global km, kc
    with kernel_state_lock:
        with execute_lock:
            if km is not None:
                try:
                    km.shutdown_kernel(now=True)
                except Exception as e:
                    send({"type": "error", "message": f"Shutdown error: {e}"})
                km = None
                kc = None
    send({"type": "response", "action": "shutdown", "status": "ok"})


def cleanup():
    """Cleanup function called on exit to ensure kernel subprocess is terminated."""
    global km
    with kernel_state_lock:
        if km is not None:
            try:
                km.shutdown_kernel(now=True)
            except Exception:
                pass
            km = None

atexit.register(cleanup)


# Main loop — read commands from stdin
try:
    for line in sys.stdin:
        line = line.strip()
        if not line:
            continue
        try:
            cmd = json.loads(line)
        except json.JSONDecodeError:
            send({"type": "error", "message": "Invalid JSON"})
            continue

        action = cmd.get("action", "")
        if action == "list_kernels":
            list_kernels()
        elif action == "start_kernel":
            start_kernel(cmd.get("kernel_name", "python3"))
        elif action == "execute":
            exec_id = cmd.get("exec_id", str(uuid.uuid4()))
            code = cmd.get("code", "")
            # Run execution in a thread so stdin isn't blocked for interrupt
            t = threading.Thread(target=execute_code, args=(code, exec_id), daemon=True)
            t.start()
        elif action == "interrupt":
            interrupt_kernel()
        elif action == "restart":
            restart_kernel()
        elif action == "shutdown":
            shutdown_kernel()
            break
        else:
            send({"type": "error", "message": f"Unknown action: {action}"})
finally:
    cleanup()
