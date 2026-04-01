use async_trait::async_trait;
use reqwest::Client;

use crate::alerts::AlertPayload;
use crate::config::WebhookConfig;

use super::Notifier;

pub struct WebhookNotifier {
    config: WebhookConfig,
    client: Client,
}

impl WebhookNotifier {
    pub fn new(config: WebhookConfig) -> Self {
        Self {
            config,
            client: Client::new(),
        }
    }
}

#[async_trait]
impl Notifier for WebhookNotifier {
    fn name(&self) -> &str {
        "webhook"
    }

    async fn send(&self, payload: &AlertPayload) -> Result<(), String> {
        let mut req = self.client.post(&self.config.url).json(payload);

        for (key, value) in &self.config.headers {
            req = req.header(key.as_str(), value.as_str());
        }

        let resp = req.send().await.map_err(|e| e.to_string())?;

        if !resp.status().is_success() {
            return Err(format!("Webhook returned status {}", resp.status()));
        }

        Ok(())
    }
}
