use crate::store::{LinkDirection, LinkEdge, Record};
use crate::value::FieldValue;
use std::cmp::Ordering;
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone)]
pub struct Query {
    expression: Expr,
}

#[derive(Debug, Clone, PartialEq)]
enum Expr {
    Comparison(Comparison),
    And(Box<Expr>, Box<Expr>),
    Or(Box<Expr>, Box<Expr>),
    Not(Box<Expr>),
}

#[derive(Debug, Clone, PartialEq)]
struct Comparison {
    target: ComparisonTarget,
    op: ComparisonOp,
    value_raw: String,
    value: FieldValue,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum ComparisonTarget {
    RecordField(String),
    Link(LinkPredicate),
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct LinkPredicate {
    direction: LinkDirection,
    rel: Option<String>,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ComparisonOp {
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
    Contains,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Word(String),
    Quoted(String),
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
    Contains,
    LeftParen,
    RightParen,
}

#[derive(Debug, Clone, PartialEq, Eq)]
pub struct QueryError {
    message: String,
}

impl QueryError {
    fn new(message: impl Into<String>) -> Self {
        Self {
            message: message.into(),
        }
    }
}

impl fmt::Display for QueryError {
    fn fmt(&self, f: &mut fmt::Formatter<'_>) -> fmt::Result {
        f.write_str(&self.message)
    }
}

impl Error for QueryError {}

impl Query {
    pub fn parse(input: &str) -> Result<Self, QueryError> {
        let tokens = tokenize(input)?;
        if tokens.is_empty() {
            return Err(QueryError::new("query cannot be empty"));
        }

        let mut parser = Parser::new(tokens);
        let expression = parser.parse_expression()?;
        if !parser.is_finished() {
            let token = parser
                .peek()
                .expect("unfinished parser should have a token");
            return Err(QueryError::new(format!(
                "unexpected token {}",
                describe_token(token)
            )));
        }

        Ok(Self { expression })
    }

    pub fn matches(&self, record: &Record) -> bool {
        self.matches_with_links(record, &[])
    }

    pub fn matches_with_links(&self, record: &Record, links: &[LinkEdge]) -> bool {
        self.expression.matches(record, links)
    }

    pub fn uses_links(&self) -> bool {
        self.expression.uses_links()
    }
}

impl Expr {
    fn matches(&self, record: &Record, links: &[LinkEdge]) -> bool {
        match self {
            Self::Comparison(comparison) => comparison.matches(record, links),
            Self::And(left, right) => left.matches(record, links) && right.matches(record, links),
            Self::Or(left, right) => left.matches(record, links) || right.matches(record, links),
            Self::Not(expression) => !expression.matches(record, links),
        }
    }

    fn uses_links(&self) -> bool {
        match self {
            Self::Comparison(comparison) => comparison.uses_links(),
            Self::And(left, right) | Self::Or(left, right) => {
                left.uses_links() || right.uses_links()
            }
            Self::Not(expression) => expression.uses_links(),
        }
    }
}

impl Comparison {
    fn matches(&self, record: &Record, links: &[LinkEdge]) -> bool {
        match &self.target {
            ComparisonTarget::RecordField(field) => self.matches_record_field(record, field),
            ComparisonTarget::Link(predicate) => predicate.matches(links, &self.value_raw),
        }
    }

    fn matches_record_field(&self, record: &Record, field: &str) -> bool {
        if self.op == ComparisonOp::Contains {
            return match record_raw_value(record, field) {
                Some(actual) => actual
                    .to_lowercase()
                    .contains(&self.value_raw.to_lowercase()),
                None => false,
            };
        }

        match record_value(record, field) {
            Some(actual) => match self.op {
                ComparisonOp::Equal => actual.value_equals(&self.value),
                ComparisonOp::NotEqual => !actual.value_equals(&self.value),
                ComparisonOp::Less => actual.value_ordering(&self.value) == Some(Ordering::Less),
                ComparisonOp::LessOrEqual => matches!(
                    actual.value_ordering(&self.value),
                    Some(Ordering::Less | Ordering::Equal)
                ),
                ComparisonOp::Greater => {
                    actual.value_ordering(&self.value) == Some(Ordering::Greater)
                }
                ComparisonOp::GreaterOrEqual => matches!(
                    actual.value_ordering(&self.value),
                    Some(Ordering::Greater | Ordering::Equal)
                ),
                ComparisonOp::Contains => {
                    unreachable!("contains comparisons are handled before typed matching")
                }
            },
            None => false,
        }
    }

    fn uses_links(&self) -> bool {
        matches!(self.target, ComparisonTarget::Link(_))
    }
}

impl LinkPredicate {
    fn matches(&self, links: &[LinkEdge], value: &str) -> bool {
        links.iter().any(|link| {
            link.direction == self.direction
                && match &self.rel {
                    Some(rel) => link.rel == *rel && link.peer_record_id == value,
                    None => link.rel == value,
                }
        })
    }
}

fn parse_comparison_target(field: &str) -> Result<ComparisonTarget, QueryError> {
    match field {
        "link.out" => {
            return Ok(ComparisonTarget::Link(LinkPredicate {
                direction: LinkDirection::Out,
                rel: None,
            }));
        }
        "link.in" => {
            return Ok(ComparisonTarget::Link(LinkPredicate {
                direction: LinkDirection::In,
                rel: None,
            }));
        }
        _ => {}
    }

    if let Some(rel) = field.strip_prefix("link.out.") {
        if rel.is_empty() {
            return Err(QueryError::new("link.out.<rel> requires a relation name"));
        }
        return Ok(ComparisonTarget::Link(LinkPredicate {
            direction: LinkDirection::Out,
            rel: Some(rel.to_owned()),
        }));
    }

    if let Some(rel) = field.strip_prefix("link.in.") {
        if rel.is_empty() {
            return Err(QueryError::new("link.in.<rel> requires a relation name"));
        }
        return Ok(ComparisonTarget::Link(LinkPredicate {
            direction: LinkDirection::In,
            rel: Some(rel.to_owned()),
        }));
    }

    if field.starts_with("link.") {
        return Err(QueryError::new(format!("unknown link predicate '{field}'")));
    }

    Ok(ComparisonTarget::RecordField(field.to_owned()))
}

fn ensure_link_operator(target: &ComparisonTarget, op: ComparisonOp) -> Result<(), QueryError> {
    if matches!(target, ComparisonTarget::Link(_)) && op != ComparisonOp::Equal {
        return Err(QueryError::new(
            "link predicates only support '='; use 'not' to negate a link predicate",
        ));
    }

    Ok(())
}

impl ComparisonOp {
    fn parse(token: Option<Token>, field: &str) -> Result<Self, QueryError> {
        match token {
            Some(Token::Equal) => Ok(Self::Equal),
            Some(Token::NotEqual) => Ok(Self::NotEqual),
            Some(Token::Less) => Ok(Self::Less),
            Some(Token::LessOrEqual) => Ok(Self::LessOrEqual),
            Some(Token::Greater) => Ok(Self::Greater),
            Some(Token::GreaterOrEqual) => Ok(Self::GreaterOrEqual),
            Some(Token::Contains) => Ok(Self::Contains),
            Some(token) => Err(QueryError::new(format!(
                "expected comparison operator after '{field}', found {}",
                describe_token(&token)
            ))),
            None => Err(QueryError::new(format!(
                "expected comparison operator after '{field}'"
            ))),
        }
    }
}

/// Resolves a sort field to a typed value using the same lookup rules as
/// query comparisons, plus the built-in `id`. Returns None when the record
/// has no value for the field.
pub fn record_sort_value(record: &Record, field: &str) -> Option<FieldValue> {
    if field == "id" {
        return Some(FieldValue::Text(record.id.clone()));
    }

    record_value(record, field)
}

fn record_raw_value(record: &Record, field: &str) -> Option<String> {
    if field == "kind" {
        return Some(record.kind.clone());
    }

    if let Some(value) = record.fields.get(field) {
        return Some(value.clone());
    }

    match field {
        "created_at" => Some(record.created_at.clone()),
        "updated_at" => Some(record.updated_at.clone()),
        _ => None,
    }
}

fn record_value(record: &Record, field: &str) -> Option<FieldValue> {
    if field == "kind" {
        return Some(FieldValue::Text(record.kind.clone()));
    }

    if let Some(value) = record.fields.get(field) {
        return Some(FieldValue::parse(value));
    }

    match field {
        "created_at" => Some(FieldValue::parse(&record.created_at)),
        "updated_at" => Some(FieldValue::parse(&record.updated_at)),
        _ => None,
    }
}

struct Parser {
    tokens: Vec<Token>,
    position: usize,
}

impl Parser {
    fn new(tokens: Vec<Token>) -> Self {
        Self {
            tokens,
            position: 0,
        }
    }

    fn is_finished(&self) -> bool {
        self.position >= self.tokens.len()
    }

    fn parse_expression(&mut self) -> Result<Expr, QueryError> {
        self.parse_or()
    }

    fn parse_or(&mut self) -> Result<Expr, QueryError> {
        let mut expression = self.parse_and()?;

        while self.consume_keyword("or") {
            let right = self.parse_and()?;
            expression = Expr::Or(Box::new(expression), Box::new(right));
        }

        Ok(expression)
    }

    fn parse_and(&mut self) -> Result<Expr, QueryError> {
        let mut expression = self.parse_not()?;

        while self.consume_keyword("and") {
            let right = self.parse_not()?;
            expression = Expr::And(Box::new(expression), Box::new(right));
        }

        Ok(expression)
    }

    fn parse_not(&mut self) -> Result<Expr, QueryError> {
        if self.consume_keyword("not") {
            return Ok(Expr::Not(Box::new(self.parse_not()?)));
        }

        self.parse_primary()
    }

    fn parse_primary(&mut self) -> Result<Expr, QueryError> {
        if self.consume_token(&Token::LeftParen) {
            let expression = self.parse_expression()?;
            self.expect_token(Token::RightParen)?;
            return Ok(expression);
        }

        Ok(Expr::Comparison(self.parse_comparison()?))
    }

    fn parse_comparison(&mut self) -> Result<Comparison, QueryError> {
        let field = self.expect_word("field name")?;
        let op = ComparisonOp::parse(self.next(), &field)?;
        let value_raw = self.expect_value("comparison value")?;
        let target = parse_comparison_target(&field)?;
        ensure_link_operator(&target, op)?;
        let value = FieldValue::parse(&value_raw);

        Ok(Comparison {
            target,
            op,
            value_raw,
            value,
        })
    }

    fn expect_value(&mut self, label: &str) -> Result<String, QueryError> {
        match self.peek() {
            Some(Token::Quoted(_)) => match self.next() {
                Some(Token::Quoted(value)) => Ok(value),
                _ => unreachable!("peeked quoted token should still be present"),
            },
            _ => self.expect_word(label),
        }
    }

    fn expect_word(&mut self, label: &str) -> Result<String, QueryError> {
        match self.next() {
            Some(Token::Word(word)) => Ok(word),
            Some(token) => Err(QueryError::new(format!(
                "expected {label}, found {}",
                describe_token(&token)
            ))),
            None => Err(QueryError::new(format!("expected {label}"))),
        }
    }

    fn expect_token(&mut self, expected: Token) -> Result<(), QueryError> {
        match self.next() {
            Some(token) if token == expected => Ok(()),
            Some(token) => Err(QueryError::new(format!(
                "expected {}, found {}",
                describe_token(&expected),
                describe_token(&token)
            ))),
            None => Err(QueryError::new(format!(
                "expected {}",
                describe_token(&expected)
            ))),
        }
    }

    fn consume_keyword(&mut self, keyword: &str) -> bool {
        match self.peek() {
            Some(Token::Word(word)) if word == keyword => {
                self.position += 1;
                true
            }
            _ => false,
        }
    }

    fn consume_token(&mut self, expected: &Token) -> bool {
        if self.peek() == Some(expected) {
            self.position += 1;
            return true;
        }
        false
    }

    fn peek(&self) -> Option<&Token> {
        self.tokens.get(self.position)
    }

    fn next(&mut self) -> Option<Token> {
        let token = self.tokens.get(self.position)?.clone();
        self.position += 1;
        Some(token)
    }
}

fn tokenize(input: &str) -> Result<Vec<Token>, QueryError> {
    let mut tokens = Vec::new();
    let bytes = input.as_bytes();
    let mut index = 0;

    while index < bytes.len() {
        match bytes[index] {
            byte if byte.is_ascii_whitespace() => {
                index += 1;
            }
            b'=' => {
                tokens.push(Token::Equal);
                index += 1;
            }
            b'!' => {
                if bytes.get(index + 1) == Some(&b'=') {
                    tokens.push(Token::NotEqual);
                    index += 2;
                } else {
                    return Err(QueryError::new("expected '=' after '!'"));
                }
            }
            b'~' => {
                if bytes.get(index + 1) == Some(&b'=') {
                    tokens.push(Token::Contains);
                    index += 2;
                } else {
                    return Err(QueryError::new("expected '=' after '~'"));
                }
            }
            b'<' => {
                if bytes.get(index + 1) == Some(&b'=') {
                    tokens.push(Token::LessOrEqual);
                    index += 2;
                } else {
                    tokens.push(Token::Less);
                    index += 1;
                }
            }
            b'>' => {
                if bytes.get(index + 1) == Some(&b'=') {
                    tokens.push(Token::GreaterOrEqual);
                    index += 2;
                } else {
                    tokens.push(Token::Greater);
                    index += 1;
                }
            }
            b'(' => {
                tokens.push(Token::LeftParen);
                index += 1;
            }
            b')' => {
                tokens.push(Token::RightParen);
                index += 1;
            }
            quote @ (b'\'' | b'"') => {
                let mut value = String::new();
                index += 1;
                loop {
                    match bytes.get(index) {
                        Some(&b'\\') => match bytes.get(index + 1) {
                            Some(_) => {
                                let end = index + 2 + trailing_continuation_bytes(bytes, index + 2);
                                value.push_str(&input[index + 1..end]);
                                index = end;
                            }
                            None => {
                                return Err(QueryError::new(
                                    "unterminated escape at end of quoted value",
                                ));
                            }
                        },
                        Some(&byte) if byte == quote => {
                            index += 1;
                            break;
                        }
                        Some(_) => {
                            let end = index + 1 + trailing_continuation_bytes(bytes, index + 1);
                            value.push_str(&input[index..end]);
                            index = end;
                        }
                        None => {
                            return Err(QueryError::new(format!(
                                "unterminated {} quoted value",
                                if quote == b'\'' { "single" } else { "double" }
                            )));
                        }
                    }
                }
                tokens.push(Token::Quoted(value));
            }
            _ => {
                let start = index;
                while index < bytes.len()
                    && !bytes[index].is_ascii_whitespace()
                    && !matches!(bytes[index], b'=' | b'!' | b'<' | b'>' | b'~' | b'(' | b')')
                {
                    index += 1;
                }
                tokens.push(Token::Word(input[start..index].to_owned()));
            }
        }
    }

    Ok(tokens)
}

fn trailing_continuation_bytes(bytes: &[u8], from: usize) -> usize {
    bytes[from..]
        .iter()
        .take_while(|byte| (0x80..0xC0).contains(*byte))
        .count()
}

fn describe_token(token: &Token) -> String {
    match token {
        Token::Word(word) => format!("'{word}'"),
        Token::Quoted(word) => format!("'{word}'"),
        Token::Equal => "'='".to_owned(),
        Token::NotEqual => "'!='".to_owned(),
        Token::Less => "'<'".to_owned(),
        Token::LessOrEqual => "'<='".to_owned(),
        Token::Greater => "'>'".to_owned(),
        Token::GreaterOrEqual => "'>='".to_owned(),
        Token::Contains => "'~='".to_owned(),
        Token::LeftParen => "'('".to_owned(),
        Token::RightParen => "')'".to_owned(),
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::collections::BTreeMap;

    fn record() -> Record {
        Record {
            id: "abc123".to_owned(),
            kind: "task".to_owned(),
            created_at: "2026-01-01T10:00:00.000Z".to_owned(),
            updated_at: "2026-01-01T11:00:00.000Z".to_owned(),
            fields: BTreeMap::from([
                ("status".to_owned(), "open".to_owned()),
                ("priority".to_owned(), "high".to_owned()),
                ("score".to_owned(), "10".to_owned()),
                ("due".to_owned(), "2026-01-02".to_owned()),
                ("stamp".to_owned(), "2026-01-02T03:04:05Z".to_owned()),
                ("active".to_owned(), "true".to_owned()),
                ("missing".to_owned(), "null".to_owned()),
            ]),
        }
    }

    fn links() -> Vec<LinkEdge> {
        vec![
            LinkEdge {
                direction: LinkDirection::Out,
                rel: "blocks".to_owned(),
                peer_record_id: "def456".to_owned(),
            },
            LinkEdge {
                direction: LinkDirection::In,
                rel: "relates".to_owned(),
                peer_record_id: "ghi789".to_owned(),
            },
        ]
    }

    #[test]
    fn parses_adjacent_and_spaced_comparisons() {
        let query = Query::parse("kind = task and status!=done").expect("query should parse");

        assert!(query.matches(&record()));
    }

    #[test]
    fn missing_fields_do_not_satisfy_inequality() {
        let query = Query::parse("absent!=done").expect("query should parse");

        assert!(!query.matches(&record()));
    }

    #[test]
    fn boolean_operators_follow_precedence() {
        let query =
            Query::parse("kind=note or kind=task and not status=done").expect("query should parse");

        assert!(query.matches(&record()));
    }

    #[test]
    fn parentheses_override_boolean_precedence() {
        let query = Query::parse("(kind=note or kind=task) and priority<medium")
            .expect("query should parse");

        assert!(query.matches(&record()));
    }

    #[test]
    fn range_comparison_operators_compare_text_values() {
        let query = Query::parse("priority>=high and priority<=high").expect("query should parse");

        assert!(query.matches(&record()));
    }

    #[test]
    fn comparisons_use_parsed_field_value_types() {
        for query in [
            "score>9",
            "score<11",
            "due=2026-01-02",
            "due>2026-01-01",
            "stamp>=2026-01-02T03:04:05Z",
            "active=true",
            "active>false",
            "missing=null",
            "priority>alpha",
        ] {
            let query = Query::parse(query).expect("query should parse");
            assert!(query.matches(&record()));
        }
    }

    #[test]
    fn dates_and_timestamps_compare_on_a_common_timeline() {
        // Record: due=2026-01-02 (date), stamp=2026-01-02T03:04:05Z (timestamp)
        for query in [
            // date field vs timestamp literal
            "due<2026-01-02T03:04:05Z",
            "due<=2026-01-02T00:00:00Z",
            "due>=2026-01-02T00:00:00Z",
            "due>2026-01-01T23:00:00Z",
            "due=2026-01-02T00:00:00Z",
            "due!=2026-01-02T03:04:05Z",
            // timestamp field vs date literal
            "stamp>2026-01-02",
            "stamp>=2026-01-02",
            "stamp<2026-01-03",
            "stamp<=2026-01-03",
            "stamp!=2026-01-02",
        ] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(parsed.matches(&record()), "query should match: {query}");
        }

        for query in [
            "due>2026-01-02T00:00:00Z",
            "due<2026-01-01T23:00:00Z",
            "due=2026-01-02T03:04:05Z",
            "due!=2026-01-02T00:00:00Z",
            "stamp<2026-01-02",
            "stamp<=2026-01-02",
            "stamp=2026-01-02",
            // missing field never matches, even against date/timestamp literals
            "absent>=2026-01-01",
            "absent!=2026-01-01T00:00:00Z",
            // text values stay incomparable with dates and timestamps
            "priority<2026-01-02",
            "priority>=2026-01-02T00:00:00Z",
            "priority=2026-01-02",
        ] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(!parsed.matches(&record()), "query should not match: {query}");
        }
    }

    #[test]
    fn ordered_comparisons_do_not_fall_back_to_raw_strings_for_mixed_types() {
        for query in [
            "score<zzz",
            "due<zzz",
            "stamp<zzz",
            "active<zzz",
            "missing<zzz",
        ] {
            let query = Query::parse(query).expect("query should parse");
            assert!(!query.matches(&record()));
        }
    }

    #[test]
    fn contains_comparisons_match_case_insensitive_substrings() {
        let mut titled = record();
        titled
            .fields
            .insert("title".to_owned(), "Fix Login Page".to_owned());

        for query in [
            "title~=login",
            "title~=LOGIN",
            "title~='Login Page'",
            "kind~=TAS",
            "created_at~=2026-01",
            "kind=task and title~=login",
            "not title~=logout",
            "(title~=logout or title~=login) and not status~=closed",
        ] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(parsed.matches(&titled), "query should match: {query}");
        }

        for query in ["title~=logout", "absent~=anything", "not title~=login"] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(!parsed.matches(&titled), "query should not match: {query}");
        }
    }

    #[test]
    fn bare_tilde_is_a_tokenizer_error() {
        let error = Query::parse("title~login").expect_err("query should not parse");

        assert!(error.to_string().contains("expected '=' after '~'"));
    }

    #[test]
    fn quoted_values_match_text_with_spaces() {
        let mut spaced = record();
        spaced
            .fields
            .insert("note".to_owned(), "hello world".to_owned());

        for query in [
            "note='hello world'",
            "note=\"hello world\"",
            "note = 'hello world'",
            "kind=task and note='hello world'",
        ] {
            let query = Query::parse(query).expect("query should parse");
            assert!(query.matches(&spaced));
        }
    }

    #[test]
    fn quoted_values_support_backslash_escapes() {
        let mut awkward = record();
        awkward
            .fields
            .insert("note".to_owned(), "it's a \"test\" \\ done".to_owned());

        for query in [
            r#"note='it\'s a "test" \\ done'"#,
            r#"note="it's a \"test\" \\ done""#,
        ] {
            let query = Query::parse(query).expect("query should parse");
            assert!(query.matches(&awkward));
        }
    }

    #[test]
    fn empty_quoted_values_match_empty_fields() {
        let mut blank = record();
        blank.fields.insert("note".to_owned(), String::new());

        for (input, expected) in [
            ("note=''", true),
            ("note=\"\"", true),
            ("note!=''", false),
            ("status=''", false),
            ("status!=''", true),
        ] {
            let query = Query::parse(input).expect("query should parse");
            assert_eq!(query.matches(&blank), expected, "query: {input}");
        }
    }

    #[test]
    fn unterminated_quoted_values_are_errors() {
        for query in ["note='oops", "note=\"oops", "note='oops\\'"] {
            let error = Query::parse(query).expect_err("query should not parse");
            assert!(error.to_string().contains("unterminated"), "query: {query}");
        }
    }

    #[test]
    fn unquoted_values_with_interior_quotes_keep_current_behavior() {
        let mut possessive = record();
        possessive
            .fields
            .insert("owner".to_owned(), "it's".to_owned());

        let query = Query::parse("owner=it's").expect("query should parse");
        assert!(query.matches(&possessive));
    }

    #[test]
    fn quoted_values_are_not_boolean_keywords() {
        let query = Query::parse("status='and'").expect("query should parse");

        let mut keywordy = record();
        keywordy.fields.insert("status".to_owned(), "and".to_owned());
        assert!(query.matches(&keywordy));
        assert!(!query.matches(&record()));
    }

    #[test]
    fn builtin_timestamps_compare_alongside_field_predicates() {
        for query in [
            "created_at>2020-01-01",
            "created_at<2999-01-01",
            "created_at>=2026-01-01T10:00:00.000Z",
            "updated_at>2026-01-01T10:30:00Z",
            "updated_at<=2026-01-01T11:00:00.000Z",
            "created_at>2020-01-01 and kind=task",
            "kind=note or updated_at>2026-01-01",
        ] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(parsed.matches(&record()), "query should match: {query}");
        }

        for query in [
            "created_at>2999-01-01",
            "updated_at<2026-01-01",
            "created_at>2020-01-01 and kind=note",
        ] {
            let parsed = Query::parse(query).expect("query should parse");
            assert!(!parsed.matches(&record()), "query should not match: {query}");
        }
    }

    #[test]
    fn user_fields_shadow_builtin_timestamps() {
        let mut shadowed = record();
        shadowed
            .fields
            .insert("created_at".to_owned(), "custom".to_owned());

        let query = Query::parse("created_at=custom").expect("query should parse");
        assert!(query.matches(&shadowed));
        let query = Query::parse("created_at>2020-01-01").expect("query should parse");
        assert!(!query.matches(&shadowed));
    }

    #[test]
    fn link_predicates_match_direction_relation_and_peer_id() {
        for query in [
            "link.out=blocks",
            "link.out.blocks=def456",
            "link.in=relates",
            "link.in.relates=ghi789",
            "kind=task and link.out.blocks=def456",
        ] {
            let query = Query::parse(query).expect("query should parse");
            assert!(query.matches_with_links(&record(), &links()));
            assert!(query.uses_links());
        }
    }

    #[test]
    fn link_predicates_compose_with_boolean_negation() {
        let query =
            Query::parse("link.out=blocks and not link.in=blocks").expect("query should parse");

        assert!(query.matches_with_links(&record(), &links()));
    }

    #[test]
    fn link_predicates_only_support_equality() {
        let error = Query::parse("link.out!=blocks").expect_err("query should not parse");

        assert!(error
            .to_string()
            .contains("link predicates only support '='"));
    }
}
