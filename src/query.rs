use crate::store::Record;
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
    field: String,
    op: ComparisonOp,
    value: FieldValue,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ComparisonOp {
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Word(String),
    Equal,
    NotEqual,
    Less,
    LessOrEqual,
    Greater,
    GreaterOrEqual,
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
        self.expression.matches(record)
    }
}

impl Expr {
    fn matches(&self, record: &Record) -> bool {
        match self {
            Self::Comparison(comparison) => comparison.matches(record),
            Self::And(left, right) => left.matches(record) && right.matches(record),
            Self::Or(left, right) => left.matches(record) || right.matches(record),
            Self::Not(expression) => !expression.matches(record),
        }
    }
}

impl Comparison {
    fn matches(&self, record: &Record) -> bool {
        let Some(actual) = record_value(record, &self.field) else {
            return false;
        };

        match self.op {
            ComparisonOp::Equal => actual == self.value,
            ComparisonOp::NotEqual => actual != self.value,
            ComparisonOp::Less => actual.value_ordering(&self.value) == Some(Ordering::Less),
            ComparisonOp::LessOrEqual => matches!(
                actual.value_ordering(&self.value),
                Some(Ordering::Less | Ordering::Equal)
            ),
            ComparisonOp::Greater => actual.value_ordering(&self.value) == Some(Ordering::Greater),
            ComparisonOp::GreaterOrEqual => matches!(
                actual.value_ordering(&self.value),
                Some(Ordering::Greater | Ordering::Equal)
            ),
        }
    }
}

fn record_value(record: &Record, field: &str) -> Option<FieldValue> {
    if field == "kind" {
        return Some(FieldValue::Text(record.kind.clone()));
    }

    record
        .fields
        .get(field)
        .map(|value| FieldValue::parse(value))
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
        let op = match self.next() {
            Some(Token::Equal) => ComparisonOp::Equal,
            Some(Token::NotEqual) => ComparisonOp::NotEqual,
            Some(Token::Less) => ComparisonOp::Less,
            Some(Token::LessOrEqual) => ComparisonOp::LessOrEqual,
            Some(Token::Greater) => ComparisonOp::Greater,
            Some(Token::GreaterOrEqual) => ComparisonOp::GreaterOrEqual,
            Some(token) => {
                return Err(QueryError::new(format!(
                    "expected comparison operator after '{field}', found {}",
                    describe_token(&token)
                )));
            }
            None => {
                return Err(QueryError::new(format!(
                    "expected comparison operator after '{field}'"
                )));
            }
        };
        let value = FieldValue::parse(&self.expect_word("comparison value")?);

        Ok(Comparison { field, op, value })
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
            _ => {
                let start = index;
                while index < bytes.len()
                    && !bytes[index].is_ascii_whitespace()
                    && !matches!(bytes[index], b'=' | b'!' | b'<' | b'>' | b'(' | b')')
                {
                    index += 1;
                }
                tokens.push(Token::Word(input[start..index].to_owned()));
            }
        }
    }

    Ok(tokens)
}

fn describe_token(token: &Token) -> String {
    match token {
        Token::Word(word) => format!("'{word}'"),
        Token::Equal => "'='".to_owned(),
        Token::NotEqual => "'!='".to_owned(),
        Token::Less => "'<'".to_owned(),
        Token::LessOrEqual => "'<='".to_owned(),
        Token::Greater => "'>'".to_owned(),
        Token::GreaterOrEqual => "'>='".to_owned(),
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
}
