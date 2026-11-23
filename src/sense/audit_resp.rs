// Sense Remote (Sürüm 4 #83): reading the audit endpoint's answer.
// RustDesk's own hbbs answers a stored audit record with an empty body; the Sense panel answers
// `200 {}` (panel-api routes/client/audit-conn.ts). Both mean "stored". An `{"error": ...}` body
// is a server failure; anything else did not come from the audit handler.

use serde_json::Value;

#[derive(Debug, PartialEq, Eq)]
pub enum AuditAnswer {
    Stored,
    ServerError(String),
    Unexpected,
}

pub fn classify_audit_body(text: &str) -> AuditAnswer {
    let text = text.trim();
    if text.is_empty() {
        return AuditAnswer::Stored;
    }
    match serde_json::from_str::<Value>(text) {
        Ok(Value::Object(m)) if m.is_empty() => AuditAnswer::Stored,
        Ok(v) => match v.get("error").and_then(|e| e.as_str()).filter(|e| !e.is_empty()) {
            Some(e) => AuditAnswer::ServerError(e.to_owned()),
            None => AuditAnswer::Unexpected,
        },
        Err(_) => AuditAnswer::Unexpected,
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn empty_and_empty_object_are_stored() {
        assert_eq!(classify_audit_body(""), AuditAnswer::Stored);
        assert_eq!(classify_audit_body("  \n"), AuditAnswer::Stored);
        assert_eq!(classify_audit_body("{}"), AuditAnswer::Stored);
        assert_eq!(classify_audit_body(" {} "), AuditAnswer::Stored);
    }

    #[test]
    fn error_body_is_server_error() {
        assert_eq!(
            classify_audit_body(r#"{"error":"db"}"#),
            AuditAnswer::ServerError("db".into())
        );
    }

    #[test]
    fn other_bodies_are_unexpected() {
        assert_eq!(classify_audit_body(r#"{"error":""}"#), AuditAnswer::Unexpected);
        assert_eq!(classify_audit_body("<html>maintenance</html>"), AuditAnswer::Unexpected);
        assert_eq!(classify_audit_body(r#"{"a":1}"#), AuditAnswer::Unexpected);
    }
}
