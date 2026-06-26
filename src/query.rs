use crate::store::Record;
use std::error::Error;
use std::fmt;

#[derive(Debug, Clone)]
pub struct Query {
    comparisons: Vec<Comparison>,
}

#[derive(Debug, Clone, PartialEq, Eq)]
struct Comparison {
    field: String,
    op: ComparisonOp,
    value: String,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
enum ComparisonOp {
    Equal,
    NotEqual,
}

#[derive(Debug, Clone, PartialEq, Eq)]
enum Token {
    Word(String),
    Equal,
    NotEqual,
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
        let mut comparisons = vec![parser.parse_comparison()?];

        while !parser.is_finished() {
            parser.expect_keyword("and")?;
            comparisons.push(parser.parse_comparison()?);
        }

        Ok(Self { comparisons })
    }

    pub fn matches(&self, record: &Record) -> bool {
        self.comparisons
            .iter()
            .all(|comparison| comparison.matches(record))
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
        }
    }
}

fn record_value(record: &Record, field: &str) -> Option<String> {
    if field == "kind" {
        return Some(record.kind.clone());
    }

    record.fields.get(field).cloned()
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

    fn parse_comparison(&mut self) -> Result<Comparison, QueryError> {
        let field = self.expect_word("field name")?;
        let op = match self.next() {
            Some(Token::Equal) => ComparisonOp::Equal,
            Some(Token::NotEqual) => ComparisonOp::NotEqual,
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
        let value = self.expect_word("comparison value")?;

        Ok(Comparison { field, op, value })
    }

    fn expect_keyword(&mut self, keyword: &str) -> Result<(), QueryError> {
        match self.next() {
            Some(Token::Word(word)) if word == keyword => Ok(()),
            Some(token) => Err(QueryError::new(format!(
                "expected '{keyword}', found {}",
                describe_token(&token)
            ))),
            None => Err(QueryError::new(format!("expected '{keyword}'"))),
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
            _ => {
                let start = index;
                while index < bytes.len()
                    && !bytes[index].is_ascii_whitespace()
                    && !matches!(bytes[index], b'=' | b'!')
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
        let query = Query::parse("missing!=done").expect("query should parse");

        assert!(!query.matches(&record()));
    }
}
