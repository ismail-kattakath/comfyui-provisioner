#!/usr/bin/env python3
"""
api_to_litegraph.py — convert ComfyUI API-format workflow JSON to LiteGraph UI format.

API format (for /api/prompt):
  { "1": { "class_type": "LoadImage", "inputs": {...} }, ... }

LiteGraph format (for ComfyUI UI file load / drag-drop):
  { "last_node_id": N, "last_link_id": N, "nodes": [...], "links": [...], ... }

Queries ComfyUI's /object_info/<NodeType> to get slot types and widget order.

Usage:
  python3 api_to_litegraph.py --in workflow_api.json --out workflow.json \
      [--host 127.0.0.1] [--port 18188]

Exit: 0 ok, 1 failure.
"""
import argparse, json, sys, urllib.request

GRID_X_STEP = 340
GRID_Y_STEP = 200
START_X = 60
START_Y = 60


def fetch_node_info(host, port, node_type):
    url = f"http://{host}:{port}/object_info/{urllib.parse.quote(node_type)}"
    try:
        with urllib.request.urlopen(url, timeout=5) as r:
            data = json.loads(r.read())
            return data.get(node_type, {})
    except Exception as e:
        print(f"[warn] Could not fetch /object_info/{node_type}: {e}", file=sys.stderr)
        return {}


import urllib.parse


def slot_type(type_str):
    """Normalise ComfyUI type strings for LiteGraph links."""
    if isinstance(type_str, list):
        return "COMBO"
    return str(type_str)


def convert(api_wf, host, port):
    nodes = []
    links = []
    link_id = 0

    # Map: (src_node_id_str, src_slot, dst_node_id_str, dst_input_name) -> link_id
    # One unique link per source→destination pair (LiteGraph requirement)
    output_to_link = {}

    # Sort node IDs numerically for stable layout
    node_ids = sorted(api_wf.keys(), key=lambda x: int(x) if x.isdigit() else 0)
    id_to_index = {nid: i for i, nid in enumerate(node_ids)}

    # First pass: fetch object_info for every node type
    node_infos = {}
    for nid in node_ids:
        ct = api_wf[nid]["class_type"]
        if ct not in node_infos:
            node_infos[ct] = fetch_node_info(host, port, ct)

    # Second pass: build nodes + collect links
    for col, nid in enumerate(node_ids):
        ct = api_wf[nid]["class_type"]
        api_inputs = api_wf[nid].get("inputs", {})
        info = node_infos.get(ct, {})

        required = info.get("input", {}).get("required", {})
        optional = info.get("input", {}).get("optional", {})
        all_input_defs = {**required, **optional}
        input_names = list(all_input_defs.keys())

        output_types = info.get("output", [])
        output_names = info.get("output_name", [f"out{i}" for i in range(len(output_types))])

        # Separate wired (node references) from widget (literal) inputs
        wired_inputs = []    # LiteGraph "inputs" array entries
        widget_values = []   # LiteGraph "widgets_values" array

        for name in input_names:
            val = api_inputs.get(name)
            type_def = all_input_defs[name]
            raw_type = type_def[0] if isinstance(type_def, (list, tuple)) else type_def

            if isinstance(val, list) and len(val) == 2 and isinstance(val[1], int):
                # Wired: [node_id_str, output_slot]
                src_nid, src_slot = str(val[0]), val[1]
                src_type = "IMAGE"
                if src_nid in node_ids:
                    src_info = node_infos.get(api_wf[src_nid]["class_type"], {})
                    out_types = src_info.get("output", [])
                    if src_slot < len(out_types):
                        src_type = slot_type(out_types[src_slot])

                # Each source→destination pair gets its own unique link ID
                key = (src_nid, src_slot, nid, name)
                if key not in output_to_link:
                    link_id += 1
                    output_to_link[key] = link_id

                wired_inputs.append({
                    "name": name,
                    "type": slot_type(raw_type),
                    "link": output_to_link[key],
                })
            else:
                # Widget value (literal)
                if val is None:
                    # Use default from info
                    type_meta = type_def[1] if isinstance(type_def, (list, tuple)) and len(type_def) > 1 else {}
                    val = type_meta.get("default", None) if isinstance(type_meta, dict) else None
                widget_values.append(val)

        # Build outputs list
        outputs = []
        for i, (otype, oname) in enumerate(zip(output_types, output_names)):
            # Find all links originating from this output (one per destination)
            out_links = [lid for (src_nid, src_slot, _dn, _inp), lid in output_to_link.items()
                         if src_nid == nid and src_slot == i]
            outputs.append({
                "name": str(oname),
                "type": slot_type(otype),
                "links": out_links,
                "slot_index": i,
            })

        x = START_X + col * GRID_X_STEP
        y = START_Y + (col % 3) * GRID_Y_STEP

        node = {
            "id": int(nid) if nid.isdigit() else col + 1,
            "type": ct,
            "pos": [x, y],
            "size": {"0": 315, "1": max(100, 46 + len(widget_values) * 30)},
            "flags": {},
            "order": col,
            "mode": 0,
            "inputs": wired_inputs,
            "outputs": outputs,
            "properties": {"Node name for S&R": ct},
            "widgets_values": widget_values,
        }
        nodes.append(node)

    # Build links array: [link_id, src_node_id, src_slot, dst_node_id, dst_slot, type]
    # We need dst info — build reverse map
    dst_map = {}  # link_id -> (dst_node_id, dst_slot, type)
    for node_obj in nodes:
        for slot_i, inp in enumerate(node_obj["inputs"]):
            lid = inp.get("link")
            if lid:
                dst_map[lid] = (node_obj["id"], slot_i, inp["type"])

    for (src_nid, src_slot, _dn, _inp), lid in output_to_link.items():
        src_node_id = int(src_nid) if src_nid.isdigit() else 0
        src_node_info = node_infos.get(api_wf.get(src_nid, {}).get("class_type", ""), {})
        out_types = src_node_info.get("output", [])
        ltype = slot_type(out_types[src_slot]) if src_slot < len(out_types) else "IMAGE"

        dst_node_id, dst_slot, _ = dst_map.get(lid, (0, 0, ltype))
        links.append([lid, src_node_id, src_slot, dst_node_id, dst_slot, ltype])

    links.sort(key=lambda x: x[0])

    return {
        "last_node_id": max((n["id"] for n in nodes), default=0),
        "last_link_id": link_id,
        "nodes": nodes,
        "links": links,
        "groups": [],
        "config": {},
        "extra": {"ds": {"scale": 0.7, "offset": [0, 0]}},
        "version": 0.4,
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--in", dest="inp", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("--host", default="127.0.0.1")
    ap.add_argument("--port", default=18188, type=int)
    a = ap.parse_args()

    with open(a.inp) as f:
        api_wf = json.load(f)

    # Detect if already in LiteGraph format
    if "nodes" in api_wf:
        print(f"[api_to_litegraph] {a.inp} already in LiteGraph format — copying as-is")
        with open(a.out, "w") as f:
            json.dump(api_wf, f, indent=2)
        return

    result = convert(api_wf, a.host, a.port)
    with open(a.out, "w") as f:
        json.dump(result, f, indent=2)
    print(f"[api_to_litegraph] {len(result['nodes'])} nodes, {len(result['links'])} links -> {a.out}")


if __name__ == "__main__":
    main()
