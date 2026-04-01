use chrono::Utc;
use serde::Serialize;

#[derive(Debug, Clone, Serialize)]
pub struct Alert {
    #[serde(rename = "type")]
    pub alert_type: String,
    pub severity: Severity,
    pub message: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node_id: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub node_addr: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq, Serialize)]
#[serde(rename_all = "lowercase")]
pub enum Severity {
    Critical,
    Warning,
    Info,
}

impl Alert {
    pub fn cluster_down(details: &str) -> Self {
        Alert {
            alert_type: "cluster_down".into(),
            severity: Severity::Critical,
            message: format!("Cluster state changed to FAIL. {details}"),
            node_id: None,
            node_addr: None,
        }
    }

    pub fn cluster_recovered() -> Self {
        Alert {
            alert_type: "cluster_recovered".into(),
            severity: Severity::Info,
            message: "Cluster state recovered to OK.".into(),
            node_id: None,
            node_addr: None,
        }
    }

    pub fn node_failed(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_failed".into(),
            severity: Severity::Critical,
            message: format!("Node {addr} marked as FAIL."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn node_recovered(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_recovered".into(),
            severity: Severity::Info,
            message: format!("Node {addr} recovered."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn node_pfail(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_possible_fail".into(),
            severity: Severity::Warning,
            message: format!("Node {addr} marked as PFAIL (possible failure)."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn failover_detected(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "failover_detected".into(),
            severity: Severity::Warning,
            message: format!("Failover: node {addr} promoted from replica to master."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn node_demoted(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_demoted".into(),
            severity: Severity::Info,
            message: format!("Node {addr} demoted from master to replica."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn memory_warning(id: &str, addr: &str, pct: u8) -> Self {
        Alert {
            alert_type: "memory_warning".into(),
            severity: Severity::Warning,
            message: format!("Node {addr} memory usage at {pct}% of maxmemory."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn memory_recovered(id: &str, addr: &str, pct: u8) -> Self {
        Alert {
            alert_type: "memory_recovered".into(),
            severity: Severity::Info,
            message: format!("Node {addr} memory usage dropped to {pct}%."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn node_joined(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_joined".into(),
            severity: Severity::Info,
            message: format!("New node joined: {addr}."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn node_disappeared(id: &str, addr: &str) -> Self {
        Alert {
            alert_type: "node_disappeared".into(),
            severity: Severity::Critical,
            message: format!("Node {addr} disappeared from cluster."),
            node_id: Some(id.to_string()),
            node_addr: Some(addr.to_string()),
        }
    }

    pub fn monitor_cannot_reach(reason: &str) -> Self {
        Alert {
            alert_type: "monitor_unreachable".into(),
            severity: Severity::Critical,
            message: format!("Monitor cannot reach Redis cluster: {reason}"),
            node_id: None,
            node_addr: None,
        }
    }

    pub fn slots_incomplete(assigned: u16) -> Self {
        Alert {
            alert_type: "slots_incomplete".into(),
            severity: Severity::Critical,
            message: format!("Only {assigned}/16384 slots assigned."),
            node_id: None,
            node_addr: None,
        }
    }
}

#[derive(Debug, Serialize)]
pub struct AlertPayload {
    pub monitor: String,
    pub timestamp: String,
    pub severity: Severity,
    pub alerts: Vec<Alert>,
}

impl AlertPayload {
    pub fn new(alerts: Vec<Alert>) -> Self {
        let severity = alerts
            .iter()
            .map(|a| a.severity)
            .min_by_key(|s| match s {
                Severity::Critical => 0,
                Severity::Warning => 1,
                Severity::Info => 2,
            })
            .unwrap_or(Severity::Info);

        AlertPayload {
            monitor: "redis-ha".into(),
            timestamp: Utc::now().to_rfc3339(),
            severity,
            alerts,
        }
    }

    pub fn subject(&self) -> String {
        let sev = match self.severity {
            Severity::Critical => "CRITICAL",
            Severity::Warning => "WARNING",
            Severity::Info => "OK",
        };
        let summary = self
            .alerts
            .first()
            .map(|a| a.message.as_str())
            .unwrap_or("No details");
        format!("[Redis HA Monitor] {sev} - {summary}")
    }

    pub fn plain_text(&self) -> String {
        let mut text = String::new();
        text.push_str("Redis HA Cluster Alert\n");
        text.push_str("══════════════════════\n\n");
        text.push_str(&format!("Time: {}\n\n", self.timestamp));
        for alert in &self.alerts {
            let sev = match alert.severity {
                Severity::Critical => "CRITICAL",
                Severity::Warning => "WARNING",
                Severity::Info => "OK",
            };
            text.push_str(&format!("{sev}: {}\n", alert.message));
            if let Some(ref addr) = alert.node_addr {
                text.push_str(&format!("  Node: {addr}\n"));
            }
            text.push('\n');
        }
        text.push_str("---\nRedis HA Monitor\n");
        text
    }

    pub fn discord_color(&self) -> u32 {
        match self.severity {
            Severity::Critical => 15158332, // red
            Severity::Warning => 16776960,  // yellow
            Severity::Info => 3066993,      // green
        }
    }
}
