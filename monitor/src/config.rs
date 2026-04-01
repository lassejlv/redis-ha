use std::env;

#[derive(Debug, Clone)]
pub struct Config {
    pub seed_node: String,
    pub redis_password: Option<String>,
    pub interval_secs: u64,
    pub memory_threshold_pct: u8,
    pub smtp: Option<SmtpConfig>,
    pub discord: Option<DiscordConfig>,
    pub webhook: Option<WebhookConfig>,
}

#[derive(Debug, Clone)]
pub struct SmtpConfig {
    pub host: String,
    pub port: u16,
    pub username: String,
    pub password: String,
    pub from: String,
    pub to: Vec<String>,
    pub tls: bool,
}

#[derive(Debug, Clone)]
pub struct DiscordConfig {
    pub webhook_url: String,
}

#[derive(Debug, Clone)]
pub struct WebhookConfig {
    pub url: String,
    pub headers: Vec<(String, String)>,
}

impl Config {
    pub fn from_env() -> Self {
        let redis_password = env::var("REDIS_PASSWORD").ok().filter(|s| !s.is_empty());
        let seed_node = env::var("MONITOR_SEED_NODE")
            .unwrap_or_else(|_| "redis-node-1:6379".to_string());
        let interval_secs = env::var("MONITOR_INTERVAL")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(10);
        let memory_threshold_pct = env::var("MONITOR_MEMORY_THRESHOLD")
            .ok()
            .and_then(|s| s.parse().ok())
            .unwrap_or(80);

        let smtp = if env::var("SMTP_ENABLED").unwrap_or_default() == "true" {
            let to = env::var("SMTP_TO")
                .unwrap_or_default()
                .split(',')
                .map(|s| s.trim().to_string())
                .filter(|s| !s.is_empty())
                .collect();
            Some(SmtpConfig {
                host: env::var("SMTP_HOST").unwrap_or_default(),
                port: env::var("SMTP_PORT")
                    .ok()
                    .and_then(|s| s.parse().ok())
                    .unwrap_or(587),
                username: env::var("SMTP_USERNAME").unwrap_or_default(),
                password: env::var("SMTP_PASSWORD").unwrap_or_default(),
                from: env::var("SMTP_FROM").unwrap_or_default(),
                to,
                tls: env::var("SMTP_TLS").unwrap_or_else(|_| "true".into()) == "true",
            })
        } else {
            None
        };

        let discord = if env::var("DISCORD_ENABLED").unwrap_or_default() == "true" {
            Some(DiscordConfig {
                webhook_url: env::var("DISCORD_WEBHOOK_URL").unwrap_or_default(),
            })
        } else {
            None
        };

        let webhook = if env::var("WEBHOOK_ENABLED").unwrap_or_default() == "true" {
            let headers = env::var("WEBHOOK_HEADERS")
                .unwrap_or_default()
                .split(',')
                .filter_map(|h| {
                    let mut parts = h.splitn(2, ':');
                    match (parts.next(), parts.next()) {
                        (Some(k), Some(v)) if !k.is_empty() => {
                            Some((k.trim().to_string(), v.trim().to_string()))
                        }
                        _ => None,
                    }
                })
                .collect();
            Some(WebhookConfig {
                url: env::var("WEBHOOK_URL").unwrap_or_default(),
                headers,
            })
        } else {
            None
        };

        Config {
            seed_node,
            redis_password,
            interval_secs,
            memory_threshold_pct,
            smtp,
            discord,
            webhook,
        }
    }

    pub fn has_any_notifier(&self) -> bool {
        self.smtp.is_some() || self.discord.is_some() || self.webhook.is_some()
    }
}
