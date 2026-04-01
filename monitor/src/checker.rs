use redis::AsyncCommands;
use std::collections::{HashMap, HashSet};
use tracing::{debug, warn};

#[derive(Debug, Clone)]
pub struct ClusterState {
    pub cluster_ok: bool,
    pub slots_assigned: u16,
    pub slots_ok: u16,
    pub known_nodes: u16,
    pub cluster_size: u16,
    pub nodes: HashMap<String, NodeSnapshot>,
}

#[derive(Debug, Clone)]
pub struct NodeSnapshot {
    pub id: String,
    pub addr: String,
    pub role: Role,
    pub flags: HashSet<String>,
    pub link_state: String,
    pub slots: Vec<String>,
    pub memory_used: u64,
    pub memory_max: u64,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum Role {
    Master,
    Replica,
}

pub async fn check_cluster(
    seed: &str,
    password: &Option<String>,
) -> Result<ClusterState, Box<dyn std::error::Error + Send + Sync>> {
    let url = build_redis_url(seed, password);
    let client = redis::Client::open(url.as_str())?;
    let mut conn = client.get_multiplexed_async_connection().await?;

    // CLUSTER INFO
    let info_raw: String = redis::cmd("CLUSTER").arg("INFO").query_async(&mut conn).await?;
    let cluster_info = parse_cluster_info(&info_raw);

    let cluster_ok = cluster_info
        .get("cluster_state")
        .map(|s| s == "ok")
        .unwrap_or(false);
    let slots_assigned = parse_u16(&cluster_info, "cluster_slots_assigned");
    let slots_ok = parse_u16(&cluster_info, "cluster_slots_ok");
    let known_nodes = parse_u16(&cluster_info, "cluster_known_nodes");
    let cluster_size = parse_u16(&cluster_info, "cluster_size");

    // CLUSTER NODES
    let nodes_raw: String = redis::cmd("CLUSTER")
        .arg("NODES")
        .query_async(&mut conn)
        .await?;
    let mut nodes = parse_cluster_nodes(&nodes_raw);

    // Fetch memory info for each node
    for node in nodes.values_mut() {
        match fetch_memory_info(&node.addr, password).await {
            Ok((used, max)) => {
                node.memory_used = used;
                node.memory_max = max;
            }
            Err(e) => {
                debug!(node = %node.addr, error = %e, "Failed to fetch memory info");
            }
        }
    }

    Ok(ClusterState {
        cluster_ok,
        slots_assigned,
        slots_ok,
        known_nodes,
        cluster_size,
        nodes,
    })
}

fn build_redis_url(addr: &str, password: &Option<String>) -> String {
    match password {
        Some(pw) => format!("redis://:{pw}@{addr}"),
        None => format!("redis://{addr}"),
    }
}

fn parse_cluster_info(raw: &str) -> HashMap<String, String> {
    raw.lines()
        .filter_map(|line| {
            let line = line.trim();
            let mut parts = line.splitn(2, ':');
            match (parts.next(), parts.next()) {
                (Some(k), Some(v)) => Some((k.to_string(), v.trim().to_string())),
                _ => None,
            }
        })
        .collect()
}

fn parse_u16(info: &HashMap<String, String>, key: &str) -> u16 {
    info.get(key)
        .and_then(|v| v.parse().ok())
        .unwrap_or(0)
}

fn parse_cluster_nodes(raw: &str) -> HashMap<String, NodeSnapshot> {
    let mut nodes = HashMap::new();
    for line in raw.lines() {
        let line = line.trim();
        if line.is_empty() {
            continue;
        }
        let parts: Vec<&str> = line.split_whitespace().collect();
        if parts.len() < 8 {
            continue;
        }

        let id = parts[0].to_string();
        let addr = parts[1].split('@').next().unwrap_or(parts[1]).to_string();
        let flags: HashSet<String> = parts[2].split(',').map(|s| s.to_string()).collect();
        let link_state = parts[7].to_string();
        let slots: Vec<String> = parts[8..].iter().map(|s| s.to_string()).collect();

        let role = if flags.contains("master") {
            Role::Master
        } else {
            Role::Replica
        };

        // Skip nodes with noaddr or handshake flags
        if flags.contains("noaddr") || flags.contains("handshake") {
            continue;
        }

        nodes.insert(
            id.clone(),
            NodeSnapshot {
                id,
                addr,
                role,
                flags,
                link_state,
                slots,
                memory_used: 0,
                memory_max: 0,
            },
        );
    }
    nodes
}

async fn fetch_memory_info(
    addr: &str,
    password: &Option<String>,
) -> Result<(u64, u64), Box<dyn std::error::Error + Send + Sync>> {
    let url = build_redis_url(addr, password);
    let client = redis::Client::open(url.as_str())?;
    let mut conn = client.get_multiplexed_async_connection().await?;

    let info_raw: String = redis::cmd("INFO")
        .arg("memory")
        .query_async(&mut conn)
        .await?;

    let mut used = 0u64;
    let mut max = 0u64;
    for line in info_raw.lines() {
        let line = line.trim();
        if let Some(val) = line.strip_prefix("used_memory:") {
            used = val.parse().unwrap_or(0);
        } else if let Some(val) = line.strip_prefix("maxmemory:") {
            max = val.parse().unwrap_or(0);
        }
    }
    Ok((used, max))
}
