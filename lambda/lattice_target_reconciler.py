# pyright: reportMissingImports=false
import json
import os

import boto3

vpclattice = boto3.client("vpc-lattice")


def _parse_map(env_name):
    raw = os.environ.get(env_name, "{}")
    try:
        return json.loads(raw)
    except json.JSONDecodeError:
        return {}


def _extract_service_name(detail):
    # ECS service task events include group like: service:<service-name>
    group = detail.get("group", "")
    if group.startswith("service:"):
        return group.split(":", 1)[1]
    return None


def _extract_task_ips(detail):
    ips = []

    for container in detail.get("containers", []):
        for ni in container.get("networkInterfaces", []):
            ip = ni.get("privateIpv4Address")
            if ip:
                ips.append(ip)

    # Keep order, drop duplicates
    seen = set()
    unique = []
    for ip in ips:
        if ip in seen:
            continue
        seen.add(ip)
        unique.append(ip)
    return unique


def lambda_handler(event, _context):
    detail = event.get("detail", {})
    last_status = detail.get("lastStatus")

    service_name = _extract_service_name(detail)
    if not service_name:
        return {"status": "ignored", "reason": "not-an-ecs-service-task-event"}

    tg_map = _parse_map("SERVICE_TARGET_GROUP_MAP")
    port_map = _parse_map("SERVICE_PORT_MAP")

    target_group_id = tg_map.get(service_name)
    port = port_map.get(service_name)

    if not target_group_id or not port:
        return {"status": "ignored", "reason": f"service-not-managed:{service_name}"}

    ips = _extract_task_ips(detail)
    if not ips:
        return {"status": "ignored", "reason": "no-task-ip-found"}

    targets = [{"id": ip, "port": int(port)} for ip in ips]

    if last_status == "RUNNING":
        vpclattice.register_targets(
            targetGroupIdentifier=target_group_id,
            targets=targets,
        )
        action = "registered"
    elif last_status == "STOPPED":
        vpclattice.deregister_targets(
            targetGroupIdentifier=target_group_id,
            targets=targets,
        )
        action = "deregistered"
    else:
        return {"status": "ignored", "reason": f"status:{last_status}"}

    return {
        "status": "ok",
        "action": action,
        "service": service_name,
        "target_group_id": target_group_id,
        "targets": targets,
    }
