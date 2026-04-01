use async_trait::async_trait;
use reqwest::Client;
use serde_json::json;

use crate::alerts::AlertPayload;
use crate::config::DiscordConfig;

use super::Notifier;

pub struct DiscordNotifier {
    config: DiscordConfig,
    client: Client,
}

impl DiscordNotifier {
    pub fn new(config: DiscordConfig) -> Self {
        Self {
            config,
            client: Client::new(),
        }
    }
}

#[async_trait]
impl Notifier for DiscordNotifier {
    fn name(&self) -> &str {
        "discord"
    }

    async fn send(&self, payload: &AlertPayload) -> Result<(), String> {
        let details = payload
            .alerts
            .iter()
            .map(|a| {
                let prefix = match a.severity {
                    crate::alerts::Severity::Critical => "**CRITICAL**",
                    crate::alerts::Severity::Warning => "**WARNING**",
                    crate::alerts::Severity::Info => "OK",
                };
                format!("{prefix}: {}", a.message)
            })
            .collect::<Vec<_>>()
            .join("\n");

        let title = match payload.severity {
            crate::alerts::Severity::Critical => "Redis HA Cluster Alert",
            crate::alerts::Severity::Warning => "Redis HA Cluster Warning",
            crate::alerts::Severity::Info => "Redis HA Cluster Recovery",
        };

        let body = json!({
            "embeds": [{
                "title": title,
                "description": details,
                "color": payload.discord_color(),
                "timestamp": payload.timestamp,
                "footer": {
                    "text": "Redis HA Monitor"
                }
            }]
        });

        let resp = self
            .client
            .post(&self.config.webhook_url)
            .json(&body)
            .send()
            .await
            .map_err(|e| e.to_string())?;

        if !resp.status().is_success() {
            return Err(format!("Discord returned status {}", resp.status()));
        }

        Ok(())
    }
}
