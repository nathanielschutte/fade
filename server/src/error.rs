use axum::{
    http::StatusCode,
    response::{IntoResponse, Response},
    Json,
};
use serde_json::json;

/// Every handler returns this. The message is shown to the user, so keep it plain.
#[derive(Debug)]
pub enum AppError {
    BadRequest(String),
    Unauthorized,
    NotFound(String),
    Conflict(String),
    /// The thing existed but is gone for good (an opened or expired snap).
    Gone(String),
    PayloadTooLarge(String),
    /// Rate limited (sign-in attempts and the like).
    TooManyRequests(String),
    /// The client is older than the minimum this server accepts. Apps show an update screen.
    UpgradeRequired(String),
    Unavailable(String),
    Internal(String),
}

pub type AppResult<T> = Result<T, AppError>;

impl AppError {
    pub fn bad(msg: impl Into<String>) -> Self {
        Self::BadRequest(msg.into())
    }
    pub fn not_found(msg: impl Into<String>) -> Self {
        Self::NotFound(msg.into())
    }
}

impl IntoResponse for AppError {
    fn into_response(self) -> Response {
        let (status, msg) = match self {
            Self::BadRequest(m) => (StatusCode::BAD_REQUEST, m),
            Self::Unauthorized => (StatusCode::UNAUTHORIZED, "Sign in to continue.".into()),
            Self::NotFound(m) => (StatusCode::NOT_FOUND, m),
            Self::Conflict(m) => (StatusCode::CONFLICT, m),
            Self::Gone(m) => (StatusCode::GONE, m),
            Self::PayloadTooLarge(m) => (StatusCode::PAYLOAD_TOO_LARGE, m),
            Self::UpgradeRequired(m) => (StatusCode::UPGRADE_REQUIRED, m),
            Self::TooManyRequests(m) => (StatusCode::TOO_MANY_REQUESTS, m),
            Self::Unavailable(m) => (StatusCode::SERVICE_UNAVAILABLE, m),
            Self::Internal(detail) => {
                tracing::error!(%detail, "internal error");
                (
                    StatusCode::INTERNAL_SERVER_ERROR,
                    "Something broke on the server. Try again.".into(),
                )
            }
        };
        if status.is_client_error() && status != StatusCode::UNAUTHORIZED {
            // The message is the user-facing text, so it's safe to log.
            tracing::debug!(status = status.as_u16(), reason = %msg, "request rejected");
        }
        (status, Json(json!({ "error": msg }))).into_response()
    }
}

impl From<sqlx::Error> for AppError {
    fn from(e: sqlx::Error) -> Self {
        Self::Internal(format!("database: {e}"))
    }
}

impl From<tokio::task::JoinError> for AppError {
    fn from(e: tokio::task::JoinError) -> Self {
        Self::Internal(format!("task: {e}"))
    }
}
