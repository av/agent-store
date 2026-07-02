use std::cmp::Ordering;

#[derive(Debug, Clone, PartialEq)]
pub enum FieldValue {
    Null,
    Boolean(bool),
    Date(String),
    Timestamp(String),
    Number(f64),
    Text(String),
}

impl FieldValue {
    pub fn parse(raw: &str) -> Self {
        if raw == "null" {
            return Self::Null;
        }

        if raw == "true" || raw == "false" {
            return Self::Boolean(raw == "true");
        }

        if looks_like_date(raw) {
            return Self::Date(raw.to_owned());
        }

        if looks_like_timestamp(raw) {
            return Self::Timestamp(raw.to_owned());
        }

        if let Ok(number) = raw.parse::<f64>() {
            if number.is_finite() {
                return Self::Number(number);
            }
        }

        Self::Text(raw.to_owned())
    }

    pub fn text_value(&self) -> Option<&str> {
        match self {
            Self::Text(value) => Some(value),
            _ => None,
        }
    }

    pub fn number_value(&self) -> Option<f64> {
        match self {
            Self::Number(value) => Some(*value),
            _ => None,
        }
    }

    pub fn timestamp_value(&self) -> Option<&str> {
        match self {
            Self::Date(value) | Self::Timestamp(value) => Some(value),
            _ => None,
        }
    }

    pub fn boolean_value(&self) -> Option<i64> {
        match self {
            Self::Boolean(value) => Some(i64::from(*value)),
            _ => None,
        }
    }

    pub fn is_null(&self) -> i64 {
        i64::from(matches!(self, Self::Null))
    }

    pub fn value_ordering(&self, other: &Self) -> Option<Ordering> {
        match (self, other) {
            (Self::Null, Self::Null) => Some(Ordering::Equal),
            (Self::Boolean(left), Self::Boolean(right)) => Some(left.cmp(right)),
            (Self::Date(left), Self::Date(right))
            | (Self::Timestamp(left), Self::Timestamp(right))
            | (Self::Text(left), Self::Text(right)) => Some(left.cmp(right)),
            (Self::Date(date), Self::Timestamp(timestamp)) => {
                Some(date_midnight_utc(date).as_str().cmp(timestamp.as_str()))
            }
            (Self::Timestamp(timestamp), Self::Date(date)) => {
                Some(timestamp.as_str().cmp(date_midnight_utc(date).as_str()))
            }
            (Self::Number(left), Self::Number(right)) => left.partial_cmp(right),
            _ => None,
        }
    }

    pub fn value_equals(&self, other: &Self) -> bool {
        match (self, other) {
            (Self::Date(_), Self::Timestamp(_)) | (Self::Timestamp(_), Self::Date(_)) => {
                self.value_ordering(other) == Some(Ordering::Equal)
            }
            _ => self == other,
        }
    }
}

fn date_midnight_utc(date: &str) -> String {
    format!("{date}T00:00:00Z")
}

fn looks_like_date(raw: &str) -> bool {
    looks_like_date_bytes(raw.as_bytes())
}

fn looks_like_date_bytes(bytes: &[u8]) -> bool {
    bytes.len() == 10
        && bytes[0..4].iter().all(u8::is_ascii_digit)
        && bytes[4] == b'-'
        && bytes[5..7].iter().all(u8::is_ascii_digit)
        && bytes[7] == b'-'
        && bytes[8..10].iter().all(u8::is_ascii_digit)
}

fn looks_like_timestamp(raw: &str) -> bool {
    let bytes = raw.as_bytes();
    bytes.len() > 10 && looks_like_date_bytes(&bytes[..10]) && bytes[10] == b'T'
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn date_and_timestamp_compare_as_midnight_utc_instant() {
        let date = FieldValue::Date("2026-07-10".to_owned());
        let midnight = FieldValue::Timestamp("2026-07-10T00:00:00Z".to_owned());
        let later = FieldValue::Timestamp("2026-07-10T09:30:00Z".to_owned());

        assert_eq!(date.value_ordering(&midnight), Some(Ordering::Equal));
        assert_eq!(midnight.value_ordering(&date), Some(Ordering::Equal));
        assert_eq!(date.value_ordering(&later), Some(Ordering::Less));
        assert_eq!(later.value_ordering(&date), Some(Ordering::Greater));

        assert!(date.value_equals(&midnight));
        assert!(midnight.value_equals(&date));
        assert!(!date.value_equals(&later));
        assert!(!later.value_equals(&date));
    }

    #[test]
    fn text_values_do_not_compare_with_dates_or_timestamps() {
        let text = FieldValue::Text("2026-07-10ish".to_owned());
        let date = FieldValue::Date("2026-07-10".to_owned());
        let stamp = FieldValue::Timestamp("2026-07-10T00:00:00Z".to_owned());

        assert_eq!(text.value_ordering(&date), None);
        assert_eq!(text.value_ordering(&stamp), None);
        assert!(!text.value_equals(&date));
        assert!(!text.value_equals(&stamp));
    }

    #[test]
    fn parses_values_by_specificity() {
        assert_eq!(FieldValue::parse("null"), FieldValue::Null);
        assert_eq!(FieldValue::parse("true"), FieldValue::Boolean(true));
        assert_eq!(
            FieldValue::parse("2026-06-26"),
            FieldValue::Date("2026-06-26".to_owned())
        );
        assert_eq!(
            FieldValue::parse("2026-06-26T12:34:56Z"),
            FieldValue::Timestamp("2026-06-26T12:34:56Z".to_owned())
        );
        assert_eq!(FieldValue::parse("42.5"), FieldValue::Number(42.5));
        assert_eq!(
            FieldValue::parse("hello"),
            FieldValue::Text("hello".to_owned())
        );
    }
}
