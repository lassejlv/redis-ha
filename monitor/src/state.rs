use std::collections::HashMap;
use std::time::Instant;

use crate::alerts::Alert;
use crate::checker::{ClusterState, Role};
use crate::config::Config;

#[derive(Debug)]
pub struct AlertRecord {
    pub resolved: bool,
    pub last_sent: Instant,
}

pub fn diff_states(
    previous: Option<&ClusterState>,
    current: &ClusterState,
    config: &Config,
    tracker: &mut HashMap<String, AlertRecord>,
) -> Vec<Alert> {
    let mut alerts = Vec::new();

    // Cluster state changes
    match previous {
        Some(prev) => {
            if prev.cluster_ok && !current.cluster_ok {
                if should_alert(tracker, "cluster_state") {
                    alerts.push(Alert::cluster_down(&format!(
                        "slots_ok={}, known_nodes={}",
                        current.slots_ok, current.known_nodes
                    )));
                }
            } else if !prev.cluster_ok && current.cluster_ok {
                resolve_alert(tracker, "cluster_state");
                alerts.push(Alert::cluster_recovered());
            }
        }
        None => {
            if !current.cluster_ok {
                if should_alert(tracker, "cluster_state") {
                    alerts.push(Alert::cluster_down(&format!(
                        "slots_ok={}, known_nodes={}",
                        current.slots_ok, current.known_nodes
                    )));
                }
            }
        }
    }

    // Slots incomplete
    if current.slots_assigned < 16384 {
        if should_alert(tracker, "slots") {
            alerts.push(Alert::slots_incomplete(current.slots_assigned));
        }
    } else {
        resolve_alert(tracker, "slots");
    }

    // Per-node checks
    let prev_nodes = previous.map(|p| &p.nodes);

    // Check current nodes against previous
    for (id, node) in &current.nodes {
        let prev_node = prev_nodes.and_then(|pn| pn.get(id));
        let short_id = &id[..id.len().min(8)];

        // Node failure detection
        let is_fail = node.flags.contains("fail");
        let is_pfail = node.flags.contains("fail?");
        let was_fail = prev_node
            .map(|pn| pn.flags.contains("fail"))
            .unwrap_or(false);
        let was_pfail = prev_node
            .map(|pn| pn.flags.contains("fail?"))
            .unwrap_or(false);

        if is_fail && !was_fail {
            let key = format!("node_fail:{short_id}");
            if should_alert(tracker, &key) {
                alerts.push(Alert::node_failed(short_id, &node.addr));
            }
        } else if !is_fail && was_fail {
            let key = format!("node_fail:{short_id}");
            resolve_alert(tracker, &key);
            alerts.push(Alert::node_recovered(short_id, &node.addr));
        }

        if is_pfail && !was_pfail && !is_fail {
            let key = format!("node_pfail:{short_id}");
            if should_alert(tracker, &key) {
                alerts.push(Alert::node_pfail(short_id, &node.addr));
            }
        } else if !is_pfail && was_pfail {
            resolve_alert(tracker, &format!("node_pfail:{short_id}"));
        }

        // Failover detection (role change)
        if let Some(prev) = prev_node {
            if prev.role == Role::Replica && node.role == Role::Master {
                let key = format!("failover:{short_id}");
                if should_alert(tracker, &key) {
                    alerts.push(Alert::failover_detected(short_id, &node.addr));
                }
            } else if prev.role == Role::Master && node.role == Role::Replica {
                let key = format!("demotion:{short_id}");
                if should_alert(tracker, &key) {
                    alerts.push(Alert::node_demoted(short_id, &node.addr));
                }
            }
        }

        // Memory threshold
        if node.memory_max > 0 {
            let pct = ((node.memory_used as f64 / node.memory_max as f64) * 100.0) as u8;
            let key = format!("memory:{short_id}");
            if pct >= config.memory_threshold_pct {
                if should_alert(tracker, &key) {
                    alerts.push(Alert::memory_warning(short_id, &node.addr, pct));
                }
            } else {
                let was_over = tracker.get(&key).map(|r| !r.resolved).unwrap_or(false);
                if was_over {
                    resolve_alert(tracker, &key);
                    alerts.push(Alert::memory_recovered(short_id, &node.addr, pct));
                }
            }
        }

        // New node detection
        if prev_node.is_none() && previous.is_some() {
            alerts.push(Alert::node_joined(short_id, &node.addr));
        }
    }

    // Nodes that disappeared
    if let Some(prev_nodes) = prev_nodes {
        for (id, prev_node) in prev_nodes {
            if !current.nodes.contains_key(id) {
                let short_id = &id[..id.len().min(8)];
                alerts.push(Alert::node_disappeared(short_id, &prev_node.addr));
            }
        }
    }

    alerts
}

fn should_alert(tracker: &mut HashMap<String, AlertRecord>, key: &str) -> bool {
    match tracker.get(key) {
        Some(record) if !record.resolved => false, // already alerted, not resolved
        _ => {
            tracker.insert(
                key.to_string(),
                AlertRecord {
                    resolved: false,
                    last_sent: Instant::now(),
                },
            );
            true
        }
    }
}

fn resolve_alert(tracker: &mut HashMap<String, AlertRecord>, key: &str) {
    if let Some(record) = tracker.get_mut(key) {
        record.resolved = true;
    }
}
