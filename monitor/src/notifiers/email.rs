use async_trait::async_trait;
use lettre::message::header::ContentType;
use lettre::transport::smtp::authentication::Credentials;
use lettre::{AsyncSmtpTransport, AsyncTransport, Message, Tokio1Executor};

use crate::alerts::AlertPayload;
use crate::config::SmtpConfig;

use super::Notifier;

pub struct EmailNotifier {
    config: SmtpConfig,
}

impl EmailNotifier {
    pub fn new(config: SmtpConfig) -> Self {
        Self { config }
    }

    fn build_transport(&self) -> Result<AsyncSmtpTransport<Tokio1Executor>, String> {
        let creds = Credentials::new(
            self.config.username.clone(),
            self.config.password.clone(),
        );

        let transport = if self.config.tls {
            AsyncSmtpTransport::<Tokio1Executor>::starttls_relay(&self.config.host)
                .map_err(|e| format!("SMTP TLS relay error: {e}"))?
                .port(self.config.port)
                .credentials(creds)
                .build()
        } else {
            AsyncSmtpTransport::<Tokio1Executor>::builder_dangerous(&self.config.host)
                .port(self.config.port)
                .credentials(creds)
                .build()
        };

        Ok(transport)
    }
}

#[async_trait]
impl Notifier for EmailNotifier {
    fn name(&self) -> &str {
        "email"
    }

    async fn send(&self, payload: &AlertPayload) -> Result<(), String> {
        let transport = self.build_transport()?;

        for to_addr in &self.config.to {
            let email = Message::builder()
                .from(
                    self.config
                        .from
                        .parse()
                        .map_err(|e| format!("Invalid from address: {e}"))?,
                )
                .to(to_addr
                    .parse()
                    .map_err(|e| format!("Invalid to address '{to_addr}': {e}"))?)
                .subject(payload.subject())
                .header(ContentType::TEXT_PLAIN)
                .body(payload.plain_text())
                .map_err(|e| format!("Failed to build email: {e}"))?;

            transport
                .send(email)
                .await
                .map_err(|e| format!("SMTP send error to {to_addr}: {e}"))?;
        }

        Ok(())
    }
}
