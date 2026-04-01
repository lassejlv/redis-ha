mod alerts;
mod checker;
mod config;
mod notifiers;
mod state;

use std::collections::HashMap;
use std::time::Duration;

use tracing::{error, info, warn};

use crate::config::Config;
use crate::notifiers::{build_notifiers, dispatch_alerts};
use crate::state::diff_states;

#[tokio::main]
async fn main() {
    tracing_subscriber::fmt()
        .with_env_filter(
            tracing_subscriber::EnvFilter::try_from_default_env()
                .unwrap_or_else(|_| "redis_ha_monitor=info".into()),
        )
        .json()
        .init();

    let config = Config::from_env();
    info!(
        interval = config.interval_secs,
        seed = %config.seed_node,
        memory_threshold = config.memory_threshold_pct,
        "Redis HA Monitor starting"
    );

    let notifiers = build_notifiers(&config);
    if !config.has_any_notifier() {
        warn!("No notification channels configured. Monitor will only log alerts.");
    } else {
        let names: Vec<&str> = notifiers.iter().map(|n| n.name()).collect();
        info!(channels = ?names, "Notification channels enabled");
    }

    let mut previous_state = None;
    let mut alert_tracker = HashMap::new();
    let mut consecutive_failures: u32 = 0;

    let mut interval = tokio::time::interval(Duration::from_secs(config.interval_secs));

    loop {
        interval.tick().await;

        match checker::check_cluster(&config.seed_node, &config.redis_password).await {
            Ok(current_state) => {
                if consecutive_failures > 0 {
                    info!("Connection restored after {} failures", consecutive_failures);
                }
                consecutive_failures = 0;

                let node_count = current_state.nodes.len();
                let masters = current_state
                    .nodes
                    .values()
                    .filter(|n| n.role == checker::Role::Master)
                    .count();

                info!(
                    cluster_ok = current_state.cluster_ok,
                    slots = current_state.slots_assigned,
                    nodes = node_count,
                    masters = masters,
                    "Health check"
                );

                let new_alerts = diff_states(
                    previous_state.as_ref(),
                    &current_state,
                    &config,
                    &mut alert_tracker,
                );

                if !new_alerts.is_empty() {
                    for alert in &new_alerts {
                        match alert.severity {
                            alerts::Severity::Critical => {
                                error!(alert_type = %alert.alert_type, "{}", alert.message)
                            }
                            alerts::Severity::Warning => {
                                warn!(alert_type = %alert.alert_type, "{}", alert.message)
                            }
                            alerts::Severity::Info => {
                                info!(alert_type = %alert.alert_type, "{}", alert.message)
                            }
                        }
                    }
                    dispatch_alerts(&notifiers, &new_alerts).await;
                }

                previous_state = Some(current_state);
            }
            Err(e) => {
                consecutive_failures += 1;
                warn!(
                    error = %e,
                    consecutive = consecutive_failures,
                    "Failed to check cluster"
                );

                if consecutive_failures == 3 {
                    let unreachable = vec![alerts::Alert::monitor_cannot_reach(&e.to_string())];
                    error!("Cluster unreachable after 3 consecutive failures");
                    dispatch_alerts(&notifiers, &unreachable).await;
                }
            }
        }
    }
}
