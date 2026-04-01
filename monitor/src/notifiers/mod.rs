pub mod discord;
pub mod email;
pub mod webhook;

use async_trait::async_trait;
use tracing::error;

use crate::alerts::{Alert, AlertPayload};
use crate::config::Config;

#[async_trait]
pub trait Notifier: Send + Sync {
    fn name(&self) -> &str;
    async fn send(&self, payload: &AlertPayload) -> Result<(), String>;
}

pub fn build_notifiers(config: &Config) -> Vec<Box<dyn Notifier>> {
    let mut notifiers: Vec<Box<dyn Notifier>> = Vec::new();

    if let Some(ref smtp) = config.smtp {
        notifiers.push(Box::new(email::EmailNotifier::new(smtp.clone())));
    }
    if let Some(ref discord) = config.discord {
        notifiers.push(Box::new(discord::DiscordNotifier::new(discord.clone())));
    }
    if let Some(ref wh) = config.webhook {
        notifiers.push(Box::new(webhook::WebhookNotifier::new(wh.clone())));
    }

    notifiers
}

pub async fn dispatch_alerts(notifiers: &[Box<dyn Notifier>], alerts: &[Alert]) {
    if alerts.is_empty() || notifiers.is_empty() {
        return;
    }

    let payload = AlertPayload::new(alerts.to_vec());

    for notifier in notifiers {
        if let Err(e) = notifier.send(&payload).await {
            error!(notifier = notifier.name(), error = %e, "Failed to send notification");
        }
    }
}
