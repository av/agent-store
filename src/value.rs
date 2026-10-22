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

/// Parses `YYYY-MM-DD` (midnight UTC) or `YYYY-MM-DDTHH:MM[:SS[.fff]]` with an
/// optional `Z` or `±HH:MM` offset (none means UTC) and returns the instant as
/// `YYYY-MM-DDTHH:MM:SS.sssZ`. Returns None unless it is a real calendar instant.
pub fn utc_instant(raw: &str) -> Option<String> {
    let bytes = raw.as_bytes();
    if !looks_like_date_bytes(bytes.get(..10)?) {
        return None;
    }
    let year = digits(&bytes[0..4])?;
    let month = digits(&bytes[5..7])?;
    let day = digits(&bytes[8..10])?;
    if !(1..=12).contains(&month) || day < 1 || day > days_in_month(year, month) {
        return None;
    }
    if bytes.len() == 10 {
        return Some(format!("{raw}T00:00:00.000Z"));
    }

    if bytes[10] != b'T' {
        return None;
    }
    let rest = &bytes[11..];
    if rest.len() < 5 || rest[2] != b':' {
        return None;
    }
    let hour = digits(&rest[0..2])?;
    let minute = digits(&rest[3..5])?;
    let mut rest = &rest[5..];
    let mut second = 0;
    let mut millis = 0;
    if rest.first() == Some(&b':') {
        second = digits(rest.get(1..3)?)?;
        rest = &rest[3..];
        if rest.first() == Some(&b'.') {
            let fraction_len = rest[1..].iter().take_while(|b| b.is_ascii_digit()).count();
            if fraction_len == 0 {
                return None;
            }
            millis = rest[1..1 + fraction_len]
                .iter()
                .chain(b"000")
                .take(3)
                .fold(0, |value, digit| value * 10 + i64::from(digit - b'0'));
            rest = &rest[1 + fraction_len..];
        }
    }
    if hour > 23 || minute > 59 || second > 59 {
        return None;
    }

    let offset_minutes = match rest {
        [] | [b'Z'] => 0,
        [sign @ (b'+' | b'-'), h1, h2, b':', m1, m2] => {
            let offset_hour = digits(&[*h1, *h2])?;
            let offset_minute = digits(&[*m1, *m2])?;
            if offset_hour > 23 || offset_minute > 59 {
                return None;
            }
            let magnitude = offset_hour * 60 + offset_minute;
            if *sign == b'+' {
                magnitude
            } else {
                -magnitude
            }
        }
        _ => return None,
    };

    let total_minutes =
        days_from_civil(year, month, day) * 1440 + hour * 60 + minute - offset_minutes;
    let (year, month, day) = civil_from_days(total_minutes.div_euclid(1440));
    if !(0..=9999).contains(&year) {
        return None;
    }
    let minute_of_day = total_minutes.rem_euclid(1440);
    Some(format!(
        "{year:04}-{month:02}-{day:02}T{:02}:{:02}:{second:02}.{millis:03}Z",
        minute_of_day / 60,
        minute_of_day % 60
    ))
}

fn digits(bytes: &[u8]) -> Option<i64> {
    if bytes.is_empty() || !bytes.iter().all(u8::is_ascii_digit) {
        return None;
    }
    Some(
        bytes
            .iter()
            .fold(0, |value, digit| value * 10 + i64::from(digit - b'0')),
    )
}

fn days_in_month(year: i64, month: i64) -> i64 {
    match month {
        2 if year % 4 == 0 && (year % 100 != 0 || year % 400 == 0) => 29,
        2 => 28,
        4 | 6 | 9 | 11 => 30,
        _ => 31,
    }
}

// Days since 1970-01-01 in the proleptic Gregorian calendar (Howard Hinnant's algorithm).
fn days_from_civil(year: i64, month: i64, day: i64) -> i64 {
    let year = if month <= 2 { year - 1 } else { year };
    let era = year.div_euclid(400);
    let year_of_era = year - era * 400;
    let month_index = (month + 9) % 12;
    let day_of_year = (153 * month_index + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    era * 146_097 + day_of_era - 719_468
}

fn civil_from_days(days: i64) -> (i64, i64, i64) {
    let days = days + 719_468;
    let era = days.div_euclid(146_097);
    let day_of_era = days - era * 146_097;
    let year_of_era =
        (day_of_era - day_of_era / 1460 + day_of_era / 36_524 - day_of_era / 146_096) / 365;
    let day_of_year = day_of_era - (365 * year_of_era + year_of_era / 4 - year_of_era / 100);
    let month_index = (5 * day_of_year + 2) / 153;
    let day = day_of_year - (153 * month_index + 2) / 5 + 1;
    let month = if month_index < 10 {
        month_index + 3
    } else {
        month_index - 9
    };
    let year = year_of_era + era * 400 + i64::from(month <= 2);
    (year, month, day)
}

pub fn parse_duration_seconds(input: &str) -> Option<i64> {
    if input.len() < 2 {
        return None;
    }
    let (digits, suffix) = input.split_at(input.len() - 1);
    let n: i64 = digits.parse().ok()?;
    if n <= 0 {
        return None;
    }
    match suffix {
        "s" => Some(n),
        "m" => n.checked_mul(60),
        "h" => n.checked_mul(3600),
        "d" => n.checked_mul(86400),
        _ => None,
    }
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
    fn parses_duration_seconds() {
        assert_eq!(parse_duration_seconds("30s"), Some(30));
        assert_eq!(parse_duration_seconds("5m"), Some(300));
        assert_eq!(parse_duration_seconds("1h"), Some(3600));
        assert_eq!(parse_duration_seconds("2d"), Some(172800));
        assert_eq!(parse_duration_seconds("0m"), None);
        assert_eq!(parse_duration_seconds("-1h"), None);
        assert_eq!(parse_duration_seconds("m"), None);
        assert_eq!(parse_duration_seconds(""), None);
        assert_eq!(parse_duration_seconds("1x"), None);
        assert_eq!(parse_duration_seconds("abc"), None);
        assert_eq!(parse_duration_seconds("1"), None);
    }

    #[test]
    fn utc_instant_normalizes_real_calendar_instants() {
        let cases = [
            ("2026-07-10", "2026-07-10T00:00:00.000Z"),
            ("2028-02-29", "2028-02-29T00:00:00.000Z"),
            ("2000-02-29T12:00Z", "2000-02-29T12:00:00.000Z"),
            ("2026-07-10T15:00:00Z", "2026-07-10T15:00:00.000Z"),
            ("2026-07-10T15:00:00", "2026-07-10T15:00:00.000Z"),
            ("2026-07-10T15:00:00.5Z", "2026-07-10T15:00:00.500Z"),
            ("2026-07-10T15:00:00.123456Z", "2026-07-10T15:00:00.123Z"),
            ("2026-11-01T10:00:00+02:00", "2026-11-01T08:00:00.000Z"),
            ("2026-03-01T01:30:00+05:30", "2026-02-28T20:00:00.000Z"),
            ("2024-03-01T00:00:00+00:01", "2024-02-29T23:59:00.000Z"),
            ("2026-12-31T23:30:00-01:00", "2027-01-01T00:30:00.000Z"),
            ("1970-01-01T00:00:00Z", "1970-01-01T00:00:00.000Z"),
        ];
        for (input, expected) in cases {
            assert_eq!(utc_instant(input).as_deref(), Some(expected), "{input}");
        }
    }

    #[test]
    fn utc_instant_rejects_impossible_or_malformed_times() {
        for input in [
            "2026-13-45",
            "2026-00-10",
            "2026-02-30",
            "2025-02-29",
            "1900-02-29",
            "2026-04-31",
            "2026-07-00",
            "2026-07-10T25:99:00Z",
            "2026-07-10T24:00:00Z",
            "2026-07-10T12:60:00Z",
            "2026-07-10T12:00:60Z",
            "2026-07-10T12:00:00+25:00",
            "2026-07-10T12:00:00+02:60",
            "2026-07-10T12:00:00+0200",
            "2026-07-10T12:00:00.Z",
            "2026-07-10T12:00:00Zjunk",
            "2026-07-10T12",
            "2026-07-10Tnoon",
            "2026-07-10 12:00:00Z",
            "0000-01-01T00:00:00+01:00",
            "garbage",
            "",
        ] {
            assert_eq!(utc_instant(input), None, "{input}");
        }
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
